//
//  PreviewPlayer.swift
//  AnyClip
//
//  Live preview of a clip with its overlay. Uses the same composition and
//  Core Animation layers as export, synchronised with AVSynchronizedLayer.
//

import SwiftUI
import AVFoundation
import QuartzCore

@MainActor
@Observable
final class PreviewController {
    let player = AVPlayer()
    private(set) var item: AVPlayerItem?
    private(set) var overlay: CALayer?
    private(set) var overlayVersion = 0
    private(set) var renderSize = CGSize(width: 720, height: 1280)
    private(set) var duration: Double = 0
    /// Clip-relative playback time.
    var currentTime: Double = 0
    private(set) var isPlaying = false
    /// True from the moment a new item is requested until its first frame is on screen.
    private(set) var isLoading = false
    var error: String?
    private var statusObservation: NSKeyValueObservation?
    private var failObserver: NSObjectProtocol?
    private var displayWatchdog: Task<Void, Never>?

    private var videoKey = ""
    private var overlayKey = ""
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var overlayTask: Task<Void, Never>?
    private var lastInput: RenderInput?
    /// Where the teaser and the clip sit in the preview.
    private(set) var timeline = OutputTimeline(main: ClipSegment(start: 0, end: 0))
    private var stopObserver: Any?
    private var playFromStartAfterLoad = false

    static let previewShortSide: Double = 720

    #if DEBUG
    nonisolated(unsafe) static weak var debugCurrent: PreviewController?
    #endif

    init() {
        #if DEBUG
        Self.debugCurrent = self
        #endif
        player.actionAtItemEnd = .pause
        observeTime()
    }

    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                // Only on a change: every write wakes the views that show it.
                let playing = self.player.rate != 0
                if playing != self.isPlaying { self.isPlaying = playing }
            }
        }
    }

    /// Releases the video decoder. Hardware decoders are limited, so a player kept alive after
    /// its editor closes can leave the next preview black.
    func teardown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        clearStop()
        statusObservation = nil
        loadTask?.cancel()
        overlayTask?.cancel()
        displayWatchdog?.cancel()
        player.replaceCurrentItem(with: nil)
        item = nil
        overlay = nil
        // Coming back to this editor builds everything again rather than finding "nothing changed".
        videoKey = ""
        overlayKey = ""
    }

    /// Called by the player view when the first video frame is (or is no longer) on screen.
    func displayReadyChanged(_ ready: Bool) {
        guard ready else { return }
        if isLoading { engineLog("preview frame on screen") }
        displayWatchdog?.cancel()
        isLoading = false
        error = nil
    }

    /// Builds the preview again from scratch, e.g. after an error.
    func retry(for clip: Clip) {
        videoKey = ""
        error = nil
        update(for: clip)
    }

    private func watch(_ item: AVPlayerItem) {
        // KVO calls back on whatever thread changed the value, so these closures must not be tied to the main actor.
        statusObservation = item.observe(\.status, options: [.new]) { @Sendable [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self, self.item === item else { return }
                if status == .failed {
                    self.isLoading = false
                    self.error = String(localized: "The video couldn’t be decoded for preview: \(message ?? "unknown error").")
                    engineLog("preview item failed: \(message ?? "?")")
                }
            }
        }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                              object: item, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            MainActor.assumeIsolated {
                self?.error = String(localized: "Playback stopped: \(message ?? "unknown error").")
            }
        }
        // If no frame shows up in time, say so instead of leaving a black screen.
        displayWatchdog?.cancel()
        displayWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.isLoading, self.error == nil else { return }
            self.isLoading = false
            self.error = String(localized: "The preview didn’t show any video. Other apps may be using the Mac’s video decoders, or the source file is damaged.")
            engineLog("preview watchdog fired: no frame displayed")
        }
    }

    /// Source time under the playhead; inside the teaser it is the teaser's own source time.
    var sourceTime: Double { timeline.source(forOutput: currentTime) }

    /// Rebuilds what changed. `playFromStart` restarts playback from the first frame once the new video is ready.
    func update(for clip: Clip, playFromStart: Bool = false) {
        guard let input = Studio.shared.renderInput(for: clip, shortSide: Self.previewShortSide) else { return }
        if timeObserver == nil { observeTime() }
        let vKey = "\(input.start)|\(input.end)|\(input.aspect.rawValue)|\(clip.keyframesData.hashValue)|\(String(describing: input.teaser))|\(input.stack?.hashValue ?? 0)"
        let oKey = "\(clip.captionStyleData.hashValue)|\(clip.hookStyleData.hashValue)|\(input.hookText)|\(input.words.count)|\(input.words.map(\.text).joined().hashValue)|\(input.watermark.hashValue)|\(input.broll.hashValue)|\(vKey)"
        lastInput = input
        if vKey != videoKey {
            videoKey = vKey
            overlayKey = oKey
            playFromStartAfterLoad = playFromStart
            reload(input)
        } else {
            if oKey != overlayKey {
                overlayKey = oKey
                rebuildOverlay(input)
            }
            if playFromStart { seek(toClipTime: 0); player.play() }
        }
    }

    private func reload(_ input: RenderInput) {
        loadTask?.cancel()
        isLoading = true
        let keepTime = currentTime
        let wasPlaying = isPlaying
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let built = try await CompositionBuilder.build(input)
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.videoComposition()
                item.audioMix = built.audioMix
                let prepared = await BRollRenderer.prepare(input)
                try Task.checkCancellation()
                let drawn = await OverlayBuilder.buildInBackground(prepared, renderSize: built.renderSize, duration: built.duration)
                try Task.checkCancellation()
                self.renderSize = built.renderSize
                self.duration = built.duration
                self.timeline = input.timeline
                self.clearStop()
                self.overlay = drawn.layer
                self.item = item
                self.overlayVersion += 1
                self.watch(item)
                self.player.replaceCurrentItem(with: item)
                if let endObserver = self.endObserver { NotificationCenter.default.removeObserver(endObserver) }
                self.endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                     object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.player.seek(to: .zero)
                        if AppSettings.loopPreview { self.player.play() }
                    }
                }
                let fromStart = self.playFromStartAfterLoad
                self.playFromStartAfterLoad = false
                await self.player.seek(to: CMTime(seconds: fromStart ? 0 : min(keepTime, max(0, built.duration - 0.1)), preferredTimescale: 600),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying || fromStart { self.player.play() }
            } catch is CancellationError {
            } catch {
                self.error = String(localized: "This clip couldn’t be prepared: \(error.localizedDescription)")
                self.isLoading = false
                engineLog("preview build failed: \(error)")
            }
        }
    }

    private func rebuildOverlay(_ input: RenderInput) {
        overlayTask?.cancel()
        let size = renderSize, length = duration
        overlayTask = Task {
            // While a slider is dragged or text is typed, only the latest value gets drawn.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            // B-roll stills come from the video, so fetch them before drawing.
            let prepared = await BRollRenderer.prepare(input)
            guard !Task.isCancelled else { return }
            let drawn = await OverlayBuilder.buildInBackground(prepared, renderSize: size, duration: length)
            guard !Task.isCancelled else { return }
            overlay = drawn.layer
            overlayVersion += 1
        }
    }

    func togglePlay() {
        clearStop()
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(toClipTime t: Double) {
        let clamped = t.clamped(to: 0...max(duration - 0.01, 0))
        currentTime = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(_ seconds: Double) { seek(toClipTime: currentTime + seconds) }

    /// Seeks to a source time inside the clip (not the teaser).
    func seek(toSource t: Double) { seek(toClipTime: timeline.output(forSource: t)) }

    /// Plays a stretch of the clip, then pauses: used to hear a teaser candidate where it was said.
    func play(sourceFrom start: Double, to end: Double) {
        clearStop()
        seek(toSource: start)
        let stop = CMTime(seconds: min(timeline.output(forSource: end), duration), preferredTimescale: 600)
        stopObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: stop)], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.player.pause()
                self?.clearStop()
            }
        }
        player.play()
    }

    private func clearStop() {
        if let stopObserver { player.removeTimeObserver(stopObserver) }
        stopObserver = nil
    }
}

struct PreviewPlayerView: NSViewRepresentable {
    let controller: PreviewController

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.playerLayer.player = controller.player
        let controller = controller
        view.onReadyForDisplay = { ready in controller.displayReadyChanged(ready) }
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.configure(item: controller.item, overlay: controller.overlay, version: controller.overlayVersion,
                       renderSize: controller.renderSize)
    }
}

/// Shows the video with its overlay, which runs inside an AVSynchronizedLayer so it follows the player.
final class PreviewNSView: NSView {
    let playerLayer = AVPlayerLayer()
    var onReadyForDisplay: ((Bool) -> Void)?
    private var readyObservation: NSKeyValueObservation?
    private var syncLayer: AVSynchronizedLayer?
    private weak var currentItem: AVPlayerItem?
    private var version = -1
    private var overlay: CALayer?
    private var renderSize = CGSize(width: 9, height: 16)
    #if DEBUG
    nonisolated(unsafe) static weak var debugCurrent: PreviewNSView?

    /// One line per layer under this view, for the `layers` debug command.
    func debugTree() -> String {
        func walk(_ l: CALayer, _ depth: Int) -> [String] {
            let line = String(repeating: "  ", count: depth) + "\(type(of: l)) subs=\(l.sublayers?.count ?? 0) speed=\(l.speed) offset=\(String(format: "%.2f", l.timeOffset))"
            return [line] + (depth < 2 ? (l.sublayers ?? []).flatMap { walk($0, depth + 1) } : [])
        }
        return layer.map { walk($0, 0).joined(separator: "\n") } ?? "no layer"
    }
    #endif

    override init(frame: NSRect) {
        super.init(frame: frame)
        #if DEBUG
        Self.debugCurrent = self
        #endif
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { @Sendable [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            Task { @MainActor [weak self] in self?.onReadyForDisplay?(ready) }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: AVPlayerItem?, overlay: CALayer?, version: Int, renderSize: CGSize) {
        self.renderSize = renderSize
        guard item !== currentItem || version != self.version else { return }
        currentItem = item
        self.version = version
        self.overlay = overlay
        // A synchronized layer doesn't redraw changes to its sublayers while the player is paused, so
        // the old overlay would stay on screen. A new one draws at the current time, playing or not.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        syncLayer?.removeFromSuperlayer()
        syncLayer = nil
        if let item {
            let sync = AVSynchronizedLayer(playerItem: item)
            if let overlay { sync.addSublayer(overlay) }
            layer?.addSublayer(sync)
            syncLayer = sync
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        let rect = AVMakeRect(aspectRatio: renderSize, insideRect: bounds)
        syncLayer?.frame = rect
        if let overlay {
            let scale = rect.width / max(renderSize.width, 1)
            overlay.anchorPoint = .zero
            overlay.bounds = CGRect(origin: .zero, size: renderSize)
            overlay.position = .zero
            // Overlay geometry uses a bottom-left origin like the export renderer.
            let flipped = syncLayer?.contentsAreFlipped() ?? false
            var t = CATransform3DMakeScale(scale, scale, 1)
            if flipped {
                t = CATransform3DConcat(CATransform3DMakeScale(1, -1, 1), CATransform3DMakeTranslation(0, renderSize.height, 0))
                t = CATransform3DConcat(t, CATransform3DMakeScale(scale, scale, 1))
            }
            overlay.transform = t
        }
        CATransaction.commit()
    }
}
