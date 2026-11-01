//
//  Studio.swift
//  AnyClip
//
//  Runs projects through the pipeline and manages the export queue.
//

import Foundation
import SwiftData
import AVFoundation
import Observation
import AppKit

nonisolated enum ProjectSource: Sendable, Hashable {
    case url(String)
    case file(URL)
}

nonisolated enum PipelineError: LocalizedError {
    case nothingToClip

    var errorDescription: String? {
        switch self {
        case .nothingToClip: String(localized: "The video is too short or has too little speech to make clips.")
        }
    }
}

nonisolated struct LiveProgress: Sendable, Hashable {
    var stage: ProjectStatus
    var fraction: Double
    var detail: String

    /// How far the whole project is, 0…1. Each step counts the same, since how long each takes depends on the video
    /// and the transcript method.
    func overall(stages: [ProjectStatus]) -> Double {
        guard let index = stages.firstIndex(of: stage), !stages.isEmpty else { return 0 }
        return (Double(index) + min(max(fraction, 0), 1)) / Double(stages.count)
    }
}

extension Project {
    /// The steps shown while a project is made. A file on this Mac has nothing to download.
    var pipelineStages: [ProjectStatus] {
        sourceURL == nil ? [.transcribing, .analyzing, .framing] : [.downloading, .transcribing, .analyzing, .framing]
    }
}

/// A project waiting for its turn, with what it needs to start.
struct PendingRun {
    let project: Project
    let source: ProjectSource
    let subtitleFile: URL?
    let context: ModelContext
}

@MainActor
@Observable
final class Studio {
    static let shared = Studio()

    /// Progress of running projects, keyed by project id.
    private(set) var live: [UUID: LiveProgress] = [:]
    /// Export progress keyed by clip id (0…1).
    private(set) var exporting: [UUID: Double] = [:]
    private(set) var exportQueue: [UUID] = []
    /// Why the last export failed, until it's been shown.
    var lastExportError: String?

    private var jobs: [UUID: Task<Void, Never>] = [:]
    /// Projects waiting for their turn, oldest first. Projects are made one at a time, so two never download
    /// with yt-dlp, transcribe or ask the AI provider at once.
    private(set) var waiting: [PendingRun] = []
    /// Recently used transcripts. Long videos have tens of thousands of words, so only a few are kept in memory.
    /// Views read transcripts while they draw, so this bookkeeping must stay out of observation: if it were
    /// observed, every read would make the view that did it draw again, without end.
    @ObservationIgnored private var transcripts: [UUID: Transcript] = [:]
    @ObservationIgnored private var transcriptUse: [UUID] = []
    private static let transcriptsKept = 4
    private var exportTask: Task<Void, Never>?
    private var currentExport: (clip: UUID, task: Task<Void, Never>)?
    private var pendingExports: [Clip] = []
    /// Teaser searches in progress, by clip id, so leaving and reopening the editor never asks the AI twice.
    private var teaserJobs: [UUID: Task<Void, Never>] = [:]
    /// The last teaser search error, by clip id.
    private(set) var teaserErrors: [UUID: String] = [:]

    // MARK: Projects

    @discardableResult
    func start(_ source: ProjectSource, options: ProjectOptions, subtitleFile: URL?, in context: ModelContext) -> Project {
        let title: String = switch source {
        case .url(let u): URL(string: u)?.host(percentEncoded: false) ?? u
        case .file(let f): f.deletingPathExtension().lastPathComponent
        }
        let project = Project(title: title, sourceURL: {
            if case .url(let u) = source { return u } else { return nil }
        }(), options: options)
        context.insert(project)
        save(context)
        run(project, source: source, subtitleFile: subtitleFile, context: context)
        if case .url(let url) = source {
            // Until the download starts the project is named after the site, so several waiting links would
            // all read "www.youtube.com". The real title replaces it as soon as it's known.
            Task {
                guard let name = await Downloader.quickTitle(url: url), !project.isDeleted, project.title == title else { return }
                project.title = name
                save(context)
            }
        }
        return project
    }

    /// What a new attempt at the project would start from: its video if it has one, otherwise its link.
    /// Nil for a file that failed before AnyClip had its own copy.
    private func retrySource(for project: Project) -> ProjectSource? {
        if let video = project.videoURL, FileManager.default.fileExists(atPath: video.path(percentEncoded: false)) { return .file(video) }
        return project.sourceURL.map { .url($0) }
    }

    func canRetry(_ project: Project) -> Bool { retrySource(for: project) != nil }

    /// The project stopped short and can be tried again.
    func offersTryAgain(_ project: Project) -> Bool {
        (project.status == .failed || project.status == .cancelled) && !isRunning(project) && canRetry(project)
    }

    func retry(_ project: Project, context: ModelContext) {
        guard let source = retrySource(for: project) else { return }
        for clip in project.clips { deleteClip(clip, context: context) }
        project.errorMessage = nil
        project.momentNotice = nil
        run(project, source: source, subtitleFile: nil, context: context)
    }

    /// Projects that were mid-run when the app quit can't resume; mark them so Try Again is offered.
    func recoverInterrupted(_ projects: [Project]) {
        for project in projects where project.status.isWorking && jobs[project.id] == nil && !isWaiting(project) {
            project.status = .cancelled
            project.errorMessage = String(localized: "AnyClip quit before this project finished.")
        }
        if let context = projects.first?.modelContext { save(context) }
    }

    /// Something is being made or exported that quitting would stop.
    var hasActiveWork: Bool { !jobs.isEmpty || !waiting.isEmpty || exportTask != nil || YouTubeUploads.shared.isActive }

    /// Stops all work when the app quits, so no download or conversion keeps running without it. The projects
    /// are offered Try Again at the next launch by `recoverInterrupted`.
    func stopEverythingForQuit() {
        waiting.removeAll()
        for job in jobs.values { job.cancel() }
        cancelExports()
        YouTubeUploads.shared.stopForQuit()
        for job in teaserJobs.values { job.cancel() }
    }

    /// Deletes a clip and its thumbnail. Exported files are left alone.
    func deleteClip(_ clip: Clip, context: ModelContext) {
        if let thumb = clip.thumbnailURL { try? FileManager.default.removeItem(at: thumb) }
        cancelExport(clip)
        if clip.youtubeState == .queued { YouTubeUploads.shared.cancel(clip) }
        teaserJobs[clip.id]?.cancel()
        context.delete(clip)
    }

    func cancel(_ project: Project) {
        if isWaiting(project) {
            // Never started, so there's nothing to stop: it just leaves the queue.
            waiting.removeAll { $0.project.id == project.id }
            live[project.id] = nil
            project.status = .cancelled
            if let context = project.modelContext { save(context) }
            return
        }
        jobs[project.id]?.cancel()
    }

    /// Being made or waiting for its turn.
    func isRunning(_ project: Project) -> Bool { jobs[project.id] != nil || isWaiting(project) }

    func isWaiting(_ project: Project) -> Bool { waiting.contains { $0.project.id == project.id } }

    /// Why a queued project hasn't started yet, or nil when it isn't waiting.
    func waitingReason(for project: Project) -> String? {
        guard let position = waiting.firstIndex(where: { $0.project.id == project.id }) else { return nil }
        // The project being made counts as one ahead.
        return position == 0
            ? String(localized: "Projects are made one at a time. This one starts automatically when the current project is finished.")
            : String(localized: "Projects are made one at a time. This one starts automatically after the \(position + 1) projects ahead of it.")
    }

    /// Stops any work on the project, then removes it, its downloaded video and audio, transcript and
    /// thumbnails. Exported clips are kept unless `includeExports` is set (they go to the Trash).
    func delete(_ project: Project, context: ModelContext, includeExports: Bool = false) {
        let id = project.id
        let folder = project.folder
        let clipIDs = Set(project.clips.map(\.id))
        let exported = includeExports ? project.clips.flatMap { [$0.exportedURL, $0.exportedThumbnailURL].compactMap { $0 } } : []
        pendingExports.removeAll { clipIDs.contains($0.id) }
        exportQueue.removeAll { clipIDs.contains($0) }
        waiting.removeAll { $0.project.id == id }
        let job = jobs[id]
        job?.cancel()
        let export = currentExport.flatMap { clipIDs.contains($0.clip) ? $0.task : nil }
        export?.cancel()
        for clipID in clipIDs { teaserJobs[clipID]?.cancel() }
        for clip in project.clips where clip.youtubeState == .queued { YouTubeUploads.shared.cancel(clip) }
        Task {
            // Wait for running work so nothing writes into the folder after it is gone.
            _ = await job?.value
            _ = await export?.value
            transcripts[id] = nil
            transcriptUse.removeAll { $0 == id }
            context.delete(project)
            save(context)
            try? FileManager.default.removeItem(at: folder)
            for url in exported {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            if let dir = exported.first?.deletingLastPathComponent(),
               (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
                try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
            }
            debugLog("deleted project folder \(folder.lastPathComponent), trashed \(exported.count) exports")
        }
    }

    private func setStage(_ project: Project, _ stage: ProjectStatus, _ fraction: Double = 0, _ detail: String = "") {
        project.status = stage
        live[project.id] = LiveProgress(stage: stage, fraction: fraction, detail: detail)
        debugLog("stage \(stage.rawValue) – \(project.title)")
    }

    /// SwiftData also saves on its own, so a failure here isn't fatal, but it must not pass unnoticed.
    private func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            debugLog("couldn't save the library: \(error)")
        }
    }

    func debugLog(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[AnyClip \(Date().formatted(date: .omitted, time: .standard))] \(message)\n".utf8))
        #endif
    }

    /// A Sendable progress callback that hops to the main actor.
    private func reporter(_ id: UUID, _ stage: ProjectStatus) -> @Sendable (Double, String) -> Void {
        { fraction, detail in
            Task { @MainActor in
                guard let current = Studio.shared.live[id], current.stage == stage else { return }
                Studio.shared.live[id] = LiveProgress(stage: stage, fraction: fraction,
                                                      detail: detail.isEmpty ? current.detail : detail)
            }
        }
    }

    /// Starts the project now, or queues it while another project is being made.
    private func run(_ project: Project, source: ProjectSource, subtitleFile: URL?, context: ModelContext) {
        let id = project.id
        jobs[id]?.cancel()
        waiting.removeAll { $0.project.id == id }
        guard jobs.isEmpty else {
            waiting.append(PendingRun(project: project, source: source, subtitleFile: subtitleFile, context: context))
            project.status = .queued
            live[id] = LiveProgress(stage: .queued, fraction: 0, detail: "")
            save(context)
            debugLog("queued \(project.title) behind \(jobs.count) running, \(waiting.count) waiting")
            return
        }
        jobs[id] = Task {
            defer {
                jobs[id] = nil
                live[id] = nil
                startNext()
            }
            do {
                try await pipeline(project, source: source, subtitleFile: subtitleFile, context: context)
                project.status = .ready
                save(context)
                debugLog("ready: \(project.clips.count) clips via \(project.momentSource)")
                for c in project.sortedClips { debugLog(String(format: "  #%d %.1f–%.1f score %.1f | %@ | hook: %@ | kf %d", c.index, c.start, c.end, c.score, c.title, c.hook, c.keyframes.count)) }
                for c in project.sortedClips {
                    for b in c.broll { debugLog(String(format: "    b-roll %.1f s %@ “%@” / “%@”", b.time - c.start, b.style.rawValue, b.lead, b.keyword)) }
                }
                if project.options.exportWhenDone { export(project.sortedClips) }
                notifyDone(project)
            } catch is CancellationError {
                project.status = .cancelled
                save(context)
            } catch {
                if Task.isCancelled {
                    project.status = .cancelled
                } else {
                    project.status = .failed
                    project.errorMessage = error.localizedDescription
                    debugLog("FAILED: \(error.localizedDescription) \(error)")
                }
                save(context)
            }
        }
    }

    /// Starts the oldest waiting project once nothing else is being made.
    private func startNext() {
        guard jobs.isEmpty, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        debugLog("starting next in queue: \(next.project.title), \(waiting.count) still waiting")
        run(next.project, source: next.source, subtitleFile: next.subtitleFile, context: next.context)
    }

    private func pipeline(_ project: Project, source: ProjectSource, subtitleFile: URL?, context: ModelContext) async throws {
        let id = project.id
        let options = project.options
        let folder = project.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var languageHint: String?
        var sampleText = project.title
        var remoteDuration: Double = 0
        var remoteInfo: RemoteVideoInfo?

        // 1. Source
        setStage(project, .downloading)
        switch source {
        case .url(let url):
            try await ToolManager.shared.ensureDownloadTools { [weak self] status in
                self?.live[id]?.detail = status
            }
            let report = reporter(id, .downloading)
            let result = try await Downloader.download(url: url, into: folder, maxHeight: AppSettings.downloadHeight) { p in
                report(p, String(localized: "\(Int(p * 100))% downloaded"))
            }
            project.title = result.info.title
            project.channel = result.info.channel
            project.videoFileName = result.videoFile.lastPathComponent
            project.audioFileName = result.audioFile?.lastPathComponent
            languageHint = result.info.language
            remoteDuration = result.info.duration
            remoteInfo = result.info
            sampleText = result.info.title + ". " + result.info.description
        case .file(let file):
            let fm = FileManager.default
            if !file.path(percentEncoded: false).hasPrefix(folder.path(percentEncoded: false)) {
                let dest = folder.appending(path: "source-video." + (file.pathExtension.isEmpty ? "mov" : file.pathExtension))
                try? fm.removeItem(at: dest)
                live[id]?.detail = String(localized: "Copying video…")
                try await Task.detached { try fm.copyItem(at: file, to: dest) }.value
                project.videoFileName = dest.lastPathComponent
            }
            if let video = project.videoURL, !((try? await AVURLAsset(url: video).load(.isPlayable)) ?? false) {
                live[id]?.detail = String(localized: "Converting video…")
                let converted = try await Transcode.toH264(video, in: folder)
                project.videoFileName = converted.lastPathComponent
            }
        }
        guard let video = project.videoURL else { throw DownloadError.nothingDownloaded }
        // DASH downloads can report an inflated duration for the video track, so trust the
        // shortest of the site's metadata, the audio file and the video file.
        var durations = [(try? await AVURLAsset(url: video).load(.duration).seconds) ?? 0]
        if let audio = project.audioURL { durations.append((try? await AVURLAsset(url: audio).load(.duration).seconds) ?? 0) }
        if remoteDuration > 0 { durations.append(remoteDuration) }
        project.duration = durations.filter { $0 > 1 && $0.isFinite }.min() ?? 0
        save(context)
        try? await Self.poster(for: video, to: project.thumbnailURL, duration: project.duration)
        try Task.checkCancellation()

        // 2. Transcript
        setStage(project, .transcribing)
        var language = options.language == "auto"
            ? SpeechEngine.guessLanguage(hint: languageHint, sampleText: sampleText) : options.language
        // Try Again reuses the transcript from the previous run.
        var transcript: Transcript? = subtitleFile == nil ? self.transcript(for: project) : nil
        if let existing = transcript {
            debugLog("reusing transcript (\(existing.words.count) words)")
            languageHint = existing.language
        } else {
            project.transcriptNotice = nil
            let made = try await makeTranscript(project, method: options.transcription, video: video, subtitleFile: subtitleFile,
                                                language: language, languageKnown: options.language != "auto" || languageHint != nil,
                                                remoteInfo: remoteInfo)
            transcript = made.transcript
            project.transcriptSource = made.source
            project.transcriptNotice = made.notice
            if made.languageDetected { languageHint = made.transcript.language; language = made.transcript.language }
        }
        guard var transcript else { throw SpeechEngineError.noSpeech }
        if options.language == "auto", languageHint == nil {
            // Re-check language from what was actually said.
            let said = transcript.words.prefix(200).map(\.text).joined(separator: " ")
            language = SpeechEngine.guessLanguage(hint: nil, sampleText: said)
            transcript.language = language
        }
        project.language = transcript.language
        try JSONEncoder().encode(transcript).write(to: project.transcriptURL, options: .atomic)
        remember(transcript, for: id)
        try Task.checkCancellation()

        // 3. Moments
        setStage(project, .analyzing)
        let request = MomentRequest(lines: transcript.lines(), count: options.clipCount, length: options.length,
                                    language: transcript.language, videoTitle: project.title, channel: project.channel,
                                    topic: options.topic)
        let report = reporter(id, .analyzing)
        let result = try await MomentFinder.find(request, provider: AIProvider.selected) { status, p in report(p, status) }
        project.momentSource = result.source
        project.momentNotice = result.notice
        try Task.checkCancellation()
        guard !result.moments.isEmpty else {
            throw PipelineError.nothingToClip
        }

        // Cut where the voice stops rather than where the transcript says the last word ends.
        var moments = result.moments
        let media = project.audioURL ?? video
        for i in moments.indices {
            let cut = await AudioSnap.clipBounds(media: media, start: moments[i].start, end: moments[i].end, words: transcript.words)
            moments[i].start = cut.start
            moments[i].end = cut.end
        }
        try Task.checkCancellation()

        // 4. Framing
        setStage(project, .framing)
        let caption = CaptionPreset.preset(options.captionPresetID).style
        var hook = HookStyle()
        hook.enabled = options.hookEnabled
        let frameReport = reporter(id, .framing)
        for (i, moment) in moments.enumerated() {
            try Task.checkCancellation()
            frameReport(Double(i) / Double(moments.count), String(localized: "Clip \(i + 1) of \(moments.count)"))
            // One pass gives the crop keyframes and what the two-speaker layout needs.
            let faces = options.faceTracking || options.stacked
                ? await FaceTracker.analyze(video: video, range: moment.start...moment.end, aspect: options.aspect)
                : nil
            let clip = Clip(index: i, candidate: moment, aspect: options.aspect, caption: caption, hook: hook)
            let centered = [FrameKeyframe.centered(at: moment.start)]
            clip.keyframes = options.faceTracking ? faces?.keyframes ?? centered : centered
            clip.shots = faces?.shots
            // Stacked only where it can work; a solo clip stays full-frame even when the project asked for stacking.
            if options.stacked, options.aspect == .vertical, clip.twoSpeaker?.allowsStacking == true {
                clip.setStacked(true)
            }
            clip.brollEnabled = options.broll
            if options.broll {
                clip.broll = BRollPlanner.plan(words: transcript.words(in: moment.start...moment.end), context: brollContext(for: clip))
            }
            clip.project = project
            context.insert(clip)
            save(context)
            if let input = renderInput(for: clip, shortSide: 540), let thumb = clip.thumbnailURL {
                do {
                    try await ClipExporter.thumbnail(input, to: thumb)
                } catch {
                    debugLog("thumbnail failed for \(clip.title): \(error)")
                }
                clip.markChanged()
            }
        }
    }

    /// Runs the chosen transcription method. If it can't produce a transcript, Apple speech
    /// recognition takes over and the notice says why.
    private func makeTranscript(_ project: Project, method: TranscriptionMethod, video: URL, subtitleFile: URL?,
                                language: String, languageKnown: Bool, remoteInfo: RemoteVideoInfo?) async throws
        -> (transcript: Transcript, source: String, notice: String?, languageDetected: Bool) {
        let id = project.id
        let report = reporter(id, .transcribing)
        var notice: String?

        switch method {
        case .subtitleFile:
            if let subtitleFile {
                let words = SubtitleParser.words(fromFile: subtitleFile)
                if !words.isEmpty {
                    return (Transcript(language: language, words: words), String(localized: "Your subtitle file"), nil, false)
                }
                notice = String(localized: "Your subtitle file had no readable captions, so the video was transcribed with Apple speech recognition.")
            } else {
                notice = String(localized: "No subtitle file was attached, so the video was transcribed with Apple speech recognition.")
            }

        case .youtube:
            if let url = project.sourceURL, Downloader.isYouTube(url) {
                live[id]?.detail = String(localized: "Getting the YouTube transcript…")
                debugLog("YouTube transcript: language \(languageKnown ? language : "unknown"), preferred \(project.options.transcriptLanguage ?? "none"), video language \(remoteInfo?.language ?? "none"), tracks \(remoteInfo.map { Downloader.captionTracks(in: $0).map(\.key) } ?? [])")
                do {
                    let result = try await Downloader.youtubeTranscript(url: url, info: remoteInfo,
                                                                        language: languageKnown ? language : nil,
                                                                        preferred: project.options.transcriptLanguage,
                                                                        into: project.folder)
                    debugLog("YouTube transcript: \(result.words.count) words, \(result.language)")
                    return (Transcript(language: result.language, words: result.words),
                            TranscriptionMethod.youtube.title, nil, true)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    debugLog("YouTube transcript failed: \(error)")
                    notice = String(localized: "\(error.localizedDescription) The video was transcribed with Apple speech recognition instead.")
                }
            } else {
                notice = String(localized: "YouTube Transcript only works with YouTube links, so this video was transcribed with Apple speech recognition.")
            }

        case .whisper:
            let model = WhisperModel.selected
            do {
                let transcript = try await WhisperEngine.transcribe(
                    media: project.audioURL ?? video, language: languageKnown ? language : nil,
                    model: model, workFolder: project.folder) { phase in
                    switch phase {
                    case .downloading(let p):
                        report(p * 0.3, String(localized: "Downloading the WhisperKit model (one time only)… \(Int(p * 100))%"))
                    case .preparing:
                        report(0.3, String(localized: "Loading the WhisperKit model…"))
                    case .transcribing(let p):
                        report(0.3 + p * 0.7, String(localized: "\(Int(p * 100))% transcribed"))
                    }
                }
                WhisperModels.shared.refresh()
                debugLog("WhisperKit: \(transcript.words.count) words, \(transcript.language)")
                return (transcript, "WhisperKit · \(model.name)", nil, !languageKnown)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                debugLog("WhisperKit failed: \(error)")
                WhisperModels.shared.refresh()
                notice = String(localized: "WhisperKit couldn’t transcribe this video: \(error.localizedDescription) Apple speech recognition was used instead.")
            }

        case .apple:
            break
        }

        live[id]?.detail = ""
        do {
            let transcript = try await SpeechEngine.transcribe(media: project.audioURL ?? video, language: language,
                                                               duration: project.duration) { phase in
                switch phase {
                case .preparingModel(let p): report(p * 0.1, String(localized: "Getting the speech model ready…"))
                case .transcribing(let p): report(0.1 + p * 0.9, String(localized: "\(Int(p * 100))% transcribed"))
                }
            }
            return (transcript, TranscriptionMethod.apple.title, notice, false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Last resort: the platform's own captions.
            if method != .youtube, let url = project.sourceURL {
                live[id]?.detail = String(localized: "Using the video’s own captions…")
                if let result = try? await Downloader.youtubeTranscript(url: url, info: remoteInfo, language: languageKnown ? language : nil,
                                                                        into: project.folder) {
                    return (Transcript(language: result.language, words: result.words), TranscriptionMethod.youtube.title,
                            String(localized: "Apple speech recognition couldn’t transcribe this video (\(error.localizedDescription)), so the YouTube transcript was used."), true)
                }
            }
            throw error
        }
    }

    static func poster(for video: URL, to url: URL, duration: Double) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let (image, _) = try await generator.image(at: CMTime(seconds: min(duration * 0.1, 30), preferredTimescale: 600))
        try ClipExporter.writeJPEG(image, to: url)
    }

    private func notifyDone(_ project: Project) {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    // MARK: Transcripts & render input

    func transcript(for project: Project) -> Transcript? {
        if let cached = transcripts[project.id] {
            remember(cached, for: project.id)
            return cached
        }
        guard let data = try? Data(contentsOf: project.transcriptURL),
              let t = try? JSONDecoder().decode(Transcript.self, from: data) else { return nil }
        remember(t, for: project.id)
        return t
    }

    private func remember(_ transcript: Transcript, for id: UUID) {
        transcripts[id] = transcript
        transcriptUse.removeAll { $0 == id }
        transcriptUse.append(id)
        while transcriptUse.count > Self.transcriptsKept {
            transcripts[transcriptUse.removeFirst()] = nil
        }
    }

    func brollContext(for clip: Clip) -> BRollPlanner.Context {
        let hook = clip.hookStyle
        let hookSeconds = hook.enabled && !clip.hook.isEmpty ? (hook.duration > 0 ? hook.duration : 4) : 0
        return BRollPlanner.Context(start: clip.start, end: clip.end, title: clip.title, hook: clip.hook, hookSeconds: hookSeconds)
    }

    func renderInput(for clip: Clip, shortSide: Double? = nil) -> RenderInput? {
        guard let project = clip.project, let video = project.videoURL else { return nil }
        return RenderInput(videoURL: video, audioURL: project.audioURL, start: clip.start, end: clip.end,
                           aspect: clip.aspect, keyframes: clip.keyframes,
                           shortSide: shortSide ?? AppSettings.exportShortSide,
                           caption: clip.captionStyle, words: clip.captionWords(transcript: transcript(for: project)),
                           hookText: clip.hook, hook: clip.hookStyle, watermark: .current,
                           broll: clip.brollEnabled ? clip.broll.filter { $0.time < clip.end && $0.time + $0.duration > clip.start } : [],
                           teaser: clip.activeTeaser, stack: clip.stackPlan)
    }

    func isFindingTeasers(_ clip: Clip) -> Bool { teaserJobs[clip.id] != nil }

    /// Starts a teaser search for a clip, or returns the one already running, and saves the suggestions on the clip.
    /// Nothing is applied until the user picks a moment.
    @discardableResult
    func refreshTeasers(for clip: Clip) -> Task<Void, Never> {
        if let running = teaserJobs[clip.id] { return running }
        let id = clip.id
        teaserErrors[id] = nil
        let analyzed = ClipSegment(start: clip.start, end: clip.end)
        let task = Task {
            defer { teaserJobs[id] = nil }
            do {
                let result = try await findTeasers(for: clip)
                // The clip may have been deleted while the AI was thinking.
                guard !Task.isCancelled, clip.modelContext != nil else { return }
                var plan = clip.teaser
                plan.candidates = result.candidates
                plan.source = result.source
                plan.notice = result.notice
                plan.analyzed = analyzed
                clip.teaser = plan
            } catch is CancellationError {
            } catch {
                teaserErrors[id] = error.localizedDescription
            }
        }
        teaserJobs[id] = task
        return task
    }

    /// What the clip's active teaser says, or nil without one.
    func teaserText(for clip: Clip) -> String? {
        guard let teaser = clip.activeTeaser, let project = clip.project else { return nil }
        let words = clip.captionWords(transcript: transcript(for: project))
        guard let range = TeaserText.wordRange(start: teaser.start, end: teaser.end, in: words) else { return nil }
        return words[range].map(\.text).joined(separator: " ")
    }

    /// New on-screen hooks for a clip. With a teaser, they're written to add to it rather than repeat it.
    func suggestHooks(for clip: Clip) async throws -> HookResult {
        guard let project = clip.project else { throw HookError.noAI }
        let words = clip.captionWords(transcript: transcript(for: project))
        let request = HookRequest(transcript: words.map(\.text).joined(separator: " "), title: clip.title,
                                  currentHook: clip.hook, teaser: teaserText(for: clip),
                                  language: project.language.isEmpty ? "en" : project.language)
        let result = try await HookWriter.suggest(request, provider: AIProvider.selected)
        debugLog("hooks via \(result.source) (teaser: \(request.teaser ?? "none")): \(result.hooks.joined(separator: " | "))")
        return result
    }

    /// Asks the AI for teaser moments in a clip.
    private func findTeasers(for clip: Clip) async throws -> TeaserResult {
        guard let project = clip.project, let video = project.videoURL else {
            return TeaserResult(candidates: [], source: "", notice: nil)
        }
        let options = project.options
        // Subtitle files only time whole lines, so word cuts inside them are estimates.
        let precise = !(options.transcription == .subtitleFile && project.transcriptNotice == nil)
        let request = TeaserRequest(words: clip.captionWords(transcript: transcript(for: project)),
                                    clipStart: clip.start, clipEnd: clip.end, title: clip.title, hook: clip.hook,
                                    language: project.language.isEmpty ? "en" : project.language,
                                    media: project.audioURL ?? video, preciseTiming: precise)
        let result = try await TeaserFinder.find(request, provider: AIProvider.selected)
        debugLog("teasers via \(result.source): \(result.candidates.count)\(result.notice.map { " – " + $0 } ?? "")")
        for c in result.candidates {
            debugLog(String(format: "  %@ %.2f–%.2f (%.1f s, clip +%.1f) score %.0f “%@” – %@ %@", c.angle.rawValue, c.start, c.end,
                            c.duration, c.start - clip.start, c.score, c.text, c.reason, c.warnings.map(\.rawValue).joined(separator: ",")))
        }
        return result
    }

    func refreshThumbnail(_ clip: Clip) {
        guard let input = renderInput(for: clip, shortSide: 540), let url = clip.thumbnailURL else { return }
        Task {
            do {
                try await ClipExporter.thumbnail(input, to: url)
            } catch {
                debugLog("thumbnail failed for \(clip.title): \(error)")
            }
            // The clip may have been deleted while the frame was being made.
            if clip.modelContext != nil { clip.markChanged() }
        }
    }

    // MARK: Export

    func export(_ clips: [Clip]) {
        for clip in clips where !exportQueue.contains(clip.id) && exporting[clip.id] == nil {
            exportQueue.append(clip.id)
            pendingExports.append(clip)
        }
        guard exportTask == nil else { return }
        exportTask = Task {
            while !pendingExports.isEmpty {
                let clip = pendingExports.removeFirst()
                exportQueue.removeAll { $0 == clip.id }
                let task = Task { await exportOne(clip) }
                currentExport = (clip.id, task)
                await task.value
                currentExport = nil
            }
            exportTask = nil
        }
    }

    func cancelExports() {
        pendingExports.removeAll()
        exportQueue.removeAll()
        currentExport?.task.cancel()
    }

    /// Stops one clip's export, whether it's running or still waiting.
    func cancelExport(_ clip: Clip) {
        pendingExports.removeAll { $0.id == clip.id }
        exportQueue.removeAll { $0 == clip.id }
        if currentExport?.clip == clip.id { currentExport?.task.cancel() }
    }

    func isQueued(_ clip: Clip) -> Bool { exportQueue.contains(clip.id) }

    var isExporting: Bool { exportTask != nil }

    private func exportOne(_ clip: Clip) async {
        do {
            _ = try await render(clip)
        } catch {
            if !(error is CancellationError) && !Task.isCancelled {
                lastExportError = String(localized: "“\(clip.title)” couldn’t be exported: \(error.localizedDescription)")
            }
            debugLog("export failed: \(error)")
        }
    }

    /// Renders a clip as it is now, with its thumbnail, for the YouTube queue. Clips may have been edited since
    /// their last export, so this is never skipped.
    func renderForUpload(_ clip: Clip) async throws -> (video: URL, thumbnail: URL?) {
        let video = try await render(clip)
        return (video, clip.exportedThumbnailURL)
    }

    private func render(_ clip: Clip) async throws -> URL {
        guard let input = renderInput(for: clip), let project = clip.project else { throw CancellationError() }
        let folder = AppPaths.exportFolder.appending(path: AppPaths.safeFileName(project.title, maxLength: 50), directoryHint: .isDirectory)
        let url = AppPaths.exportFile(in: folder, index: clip.index, title: clip.title, previous: clip.exportedURL)
        let hevc = AppSettings.videoCodec == .hevc
        let id = clip.id
        exporting[id] = 0
        defer { exporting[id] = nil }
        try await ClipExporter.export(input, to: url, hevc: hevc) { p in
            Task { @MainActor in if Studio.shared.exporting[id] != nil { Studio.shared.exporting[id] = p } }
        }
        // The clip may have been deleted while it rendered; the finished file stays in the folder either way.
        guard clip.modelContext != nil else { throw CancellationError() }
        clip.exportedPath = url.path(percentEncoded: false)
        clip.exportedAt = Date()
        debugLog("exported \(url.path(percentEncoded: false))")
        await exportThumbnail(of: clip, video: url, in: folder)
        return url
    }

    /// Saves the video's first frame beside it, ready to upload as its cover. The video is fine without it, so a
    /// failure here only says so.
    private func exportThumbnail(of clip: Clip, video: URL, in folder: URL) async {
        let url = AppPaths.thumbnailFile(in: folder, index: clip.index, previous: clip.exportedThumbnailURL)
        do {
            try await ClipExporter.saveFirstFrame(of: video, to: url)
            guard clip.modelContext != nil else { return }
            clip.exportedThumbnailPath = url.path(percentEncoded: false)
            debugLog("exported \(url.path(percentEncoded: false))")
        } catch {
            lastExportError = String(localized: "“\(clip.title)” was exported, but its thumbnail couldn’t be saved: \(error.localizedDescription)")
            debugLog("thumbnail export failed: \(error)")
        }
    }
}
