//
//  YouTubeUploads.swift
//  AnyClip
//
//  The upload queue. Clips go one at a time: rendered fresh, sent to YouTube as
//  private with a publish time, then given their thumbnail. Once a clip is up,
//  YouTube publishes it on time even if this Mac is off. The queue is saved on
//  the clips, so it carries on after a restart.
//

import Foundation
import ImageIO
import Observation
import SwiftData

@MainActor
@Observable
final class YouTubeUploads {
    static let shared = YouTubeUploads()

    enum Phase: Equatable {
        case waiting
        case rendering
        case uploading(Double)
        case thumbnail
    }

    private(set) var phases: [UUID: Phase] = [:]
    /// While YouTube's daily limit is used up: when the queue carries on.
    private(set) var pausedUntil: Date?
    private var queue: [Clip] = []
    private var worker: Task<Void, Never>?
    private var current: (id: UUID, task: Task<Void, Never>)?
    #if DEBUG
    var debugPNGClips: Set<UUID> = []
    #endif

    var isActive: Bool { worker != nil }
    var pendingCount: Int { queue.count + (current == nil ? 0 : 1) }

    func phase(of clip: Clip) -> Phase? { phases[clip.id] }

    /// Queues clips with their publish times, in order.
    func schedule(_ clips: [Clip], at times: [Date], madeForKids: Bool) {
        for (clip, time) in zip(clips, times) where !queue.contains(where: { $0.id == clip.id }) && current?.id != clip.id {
            clip.youtubePublishAt = time
            clip.youtubeMadeForKids = madeForKids
            clip.youtubeState = .queued
            clip.youtubeError = nil
            clip.youtubeNotice = nil
            queue.append(clip)
            phases[clip.id] = .waiting
        }
        saveChanges(of: clips.first)
        startIfNeeded()
    }

    /// Picks up clips that were still queued when the app last closed.
    func resume(_ clips: [Clip]) {
        let waiting = Set(queue.map(\.id))
        let queued = clips.filter { $0.youtubeState == .queued && !waiting.contains($0.id) && current?.id != $0.id }
            .sorted { ($0.youtubePublishAt ?? .distantPast) < ($1.youtubePublishAt ?? .distantPast) }
        guard !queued.isEmpty else { return }
        for clip in queued {
            queue.append(clip)
            phases[clip.id] = .waiting
        }
        startIfNeeded()
    }

    /// Takes a clip out of the queue, stopping its upload if it's the one in progress. Nothing was published.
    func cancel(_ clip: Clip) {
        queue.removeAll { $0.id == clip.id }
        phases[clip.id] = nil
        if current?.id == clip.id { current?.task.cancel() }
        clip.youtubeState = nil
        clip.youtubePublishAt = nil
        saveChanges(of: clip)
    }

    func stopForQuit() {
        // The clips stay queued, so the next launch continues.
        worker?.cancel()
        current?.task.cancel()
    }

    private func saveChanges(of clip: Clip?) {
        do {
            try clip?.modelContext?.save()
        } catch {
            engineLog("couldn't save the upload queue: \(error)")
        }
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task {
            defer { worker = nil }
            while !queue.isEmpty, !Task.isCancelled {
                let clip = queue.removeFirst()
                let task = Task { await run(clip) }
                current = (clip.id, task)
                await task.value
                current = nil
                if let until = pausedUntil {
                    // Everything after this clip needs the same limit, so wait here.
                    try? await Task.sleep(for: .seconds(max(until.timeIntervalSinceNow, 1)))
                    pausedUntil = nil
                }
            }
        }
    }

    private func run(_ clip: Clip) async {
        let id = clip.id
        defer { if phases[id] != .waiting { phases[id] = nil } }
        guard clip.modelContext != nil else { return }
        do {
            guard let publishAt = clip.youtubePublishAt, publishAt > Date().addingTimeInterval(60) else {
                throw YouTubeError.scheduleTimePassed
            }
            phases[id] = .rendering
            let files = try await Studio.shared.renderForUpload(clip)
            try Task.checkCancellation()
            let draft = YouTubeDraft(title: clip.title, caption: clip.summary)
            let metadata = try YouTubeClient.metadata(draft, publishAt: publishAt, madeForKids: clip.youtubeMadeForKids)
            phases[id] = .uploading(0)
            let videoID = try await send(files.video, metadata: metadata, id: id)
            guard clip.modelContext != nil else { return }
            clip.youtubeVideoID = videoID
            clip.youtubeState = .scheduled
            saveChanges(of: clip)
            phases[id] = .thumbnail
            clip.youtubeNotice = await uploadThumbnail(thumbnailToSend(files.thumbnail, clip: id), videoID: videoID)
            saveChanges(of: clip)
        } catch is CancellationError {
            // Cancelled by the person, or the app is quitting and the clip stays queued.
        } catch YouTubeError.dailyLimit {
            let reset = YouTubeTime.nextQuotaReset()
            pausedUntil = reset
            queue.insert(clip, at: 0)
            phases[id] = .waiting
            engineLog("YouTube daily limit reached, waiting until \(YouTubeTime.display(reset))")
        } catch {
            if case YouTubeError.signInExpired = error { YouTubeAccount.shared.markDisconnected() }
            guard clip.modelContext != nil else { return }
            clip.youtubeState = .failed
            clip.youtubeError = error.localizedDescription
            engineLog("YouTube upload failed: \(error.localizedDescription)")
            saveChanges(of: clip)
        }
    }

    /// Sends the file, starting over once if YouTube ended the session.
    private func send(_ file: URL, metadata: Data, id: UUID) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as? Int) ?? 0
        let tokens: YouTubeClient.TokenProvider = { try await YouTubeTokens.shared.accessToken() }
        let report: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor in
                if case .uploading = YouTubeUploads.shared.phases[id] { YouTubeUploads.shared.phases[id] = .uploading(fraction) }
            }
        }
        for attempt in 1...2 {
            let address = try await YouTubeClient.startUpload(metadata: metadata, fileSize: size, token: tokens())
            do {
                return try await YouTubeClient.sendFile(file, to: address, token: tokens, progress: report)
            } catch YouTubeError.sessionExpired where attempt == 1 {
                engineLog("YouTube upload session expired, starting over")
            }
        }
        throw YouTubeError.sessionExpired
    }

    private func thumbnailToSend(_ file: URL?, clip: UUID) -> URL? {
        #if DEBUG
        // The `ytthumbtest` comparison: the same frame, as a PNG.
        if debugPNGClips.contains(clip), let file, let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let png = file.deletingPathExtension().appendingPathExtension("png")
            if let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) { return png }
            }
        }
        #endif
        return file
    }

    /// Returns a note when the video went up but its thumbnail didn't: the video is still scheduled.
    private func uploadThumbnail(_ file: URL?, videoID: String) async -> String? {
        guard let file else { return String(localized: "The thumbnail couldn’t be made, so YouTube will choose one.") }
        do {
            try await YouTubeClient.setThumbnail(file, videoID: videoID, token: YouTubeTokens.shared.accessToken())
            return nil
        } catch {
            engineLog("YouTube thumbnail failed: \(error.localizedDescription)")
            return String(localized: "The video is scheduled, but YouTube didn’t accept its thumbnail: \(error.localizedDescription) Custom thumbnails need a verified YouTube channel.")
        }
    }
}
