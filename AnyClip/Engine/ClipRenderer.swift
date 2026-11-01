//
//  ClipRenderer.swift
//  AnyClip
//
//  Builds the AVFoundation composition for a clip (trim + reframing) and the
//  Core Animation overlay (captions, hook, watermark). The overlay is used by
//  AVSynchronizedLayer for preview and by AVVideoCompositionCoreAnimationTool
//  for export, so both paths share one implementation.
//

import Foundation
import AVFoundation
import QuartzCore
import UniformTypeIdentifiers

nonisolated struct RenderInput: Sendable {
    var videoURL: URL
    var audioURL: URL?
    var start: Double
    var end: Double
    var aspect: AspectRatio
    var keyframes: [FrameKeyframe]
    var shortSide: Double = 1080
    var caption: CaptionStyle
    /// Caption words in source time.
    var words: [Word]
    var hookText: String
    var hook: HookStyle
    var watermark: WatermarkSettings
    /// B-roll cards, in source time. Empty when the clip has B-roll turned off.
    var broll: [BRollInsert] = []
    /// Stills for the cards, filled in by `BRollRenderer.prepare`.
    var brollSources: [UUID: BRollSource] = [:]
    /// A moment from inside the clip played before it (a cold open), in source time.
    var teaser: ClipSegment?
    /// The two-speaker layout plan in source time; nil renders the ordinary full-frame crop.
    var stack: [LayoutSegment]?

    var timeline: OutputTimeline { OutputTimeline(teaser: teaser, main: ClipSegment(start: start, end: end)) }
}

nonisolated final class BuiltComposition: @unchecked Sendable {
    let composition: AVMutableComposition
    let renderSize: CGSize
    let frameDuration: CMTime
    let instruction: AVVideoCompositionInstruction
    let duration: Double
    /// Softens the audio at the cut after a teaser; nil without one.
    let audioMix: AVAudioMix?

    init(composition: AVMutableComposition, renderSize: CGSize, frameDuration: CMTime,
         instruction: AVVideoCompositionInstruction, duration: Double, audioMix: AVAudioMix? = nil) {
        self.composition = composition
        self.renderSize = renderSize
        self.frameDuration = frameDuration
        self.instruction = instruction
        self.duration = duration
        self.audioMix = audioMix
    }

    func videoComposition(animationTool: AVVideoCompositionCoreAnimationTool? = nil) -> AVVideoComposition {
        var config = AVVideoComposition.Configuration()
        config.renderSize = renderSize
        config.frameDuration = frameDuration
        config.instructions = [instruction]
        config.animationTool = animationTool
        return AVVideoComposition(configuration: config)
    }
}

nonisolated enum RenderError: LocalizedError {
    case noVideoTrack
    case invalidComposition
    case exportFailed(String)
    case imageNotWritten

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: String(localized: "The source file has no video track.")
        case .invalidComposition: String(localized: "This clip’s timing couldn’t be turned into video. Try nudging the trim handles slightly.")
        case .exportFailed(let m): String(localized: "Export failed: \(m)")
        case .imageNotWritten: String(localized: "The thumbnail couldn’t be saved.")
        }
    }
}

nonisolated enum CompositionBuilder {
    static func sourceGeometry(_ track: AVAssetTrack) async throws -> (size: CGSize, transform: CGAffineTransform) {
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let fixed = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return (CGSize(width: abs(rect.width), height: abs(rect.height)), fixed)
    }

    /// Seconds as 1/600 s ticks, rounded to the nearest tick.
    static func ticks(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * 600).rounded()), timescale: 600)
    }

    static func build(_ input: RenderInput) async throws -> BuiltComposition {
        let videoAsset = AVURLAsset(url: input.videoURL)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }
        let assetDuration = try await videoAsset.load(.duration).seconds
        func clamped(_ s: ClipSegment) -> ClipSegment {
            let a = max(0, s.start)
            let b = min(s.end, assetDuration > 0 ? assetDuration : s.end)
            return ClipSegment(start: a, end: max(a + 0.5, b))
        }
        // An optional teaser, then the clip. Both come from the same source, so size and frame rate match.
        var pieces: [(segment: ClipSegment, range: CMTimeRange, at: CMTime)] = []
        var cursor = CMTime.zero
        for segment in input.timeline.pieces.map({ clamped($0.segment) }) {
            let range = CMTimeRange(start: ticks(segment.start), duration: ticks(segment.duration))
            pieces.append((segment, range, cursor))
            cursor = cursor + range.duration
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RenderError.noVideoTrack
        }
        for piece in pieces {
            try videoTrack.insertTimeRange(piece.range, of: sourceVideo, at: piece.at)
        }
        /// Output time of a source time inside a piece, in whole ticks from the piece's start.
        func output(_ t: Double, in piece: (segment: ClipSegment, range: CMTimeRange, at: CMTime)) -> CMTime {
            min(piece.at + ticks(t - piece.segment.start), piece.at + piece.range.duration)
        }

        // The stacked layout draws the source a second time for the lower panel. That copy only has media where
        // the plan stacks, so it is never decoded while the clip is full-frame.
        let plan = input.aspect == .vertical ? input.stack?.filter { $0.end > $0.start } : nil
        var panelTrack: AVMutableCompositionTrack?
        if let plan, plan.contains(where: \.isStacked) {
            panelTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            for piece in pieces {
                for seg in plan where seg.isStacked && seg.end > piece.segment.start && seg.start < piece.segment.end {
                    let a = output(max(seg.start, piece.segment.start), in: piece)
                    let b = output(min(seg.end, piece.segment.end), in: piece)
                    guard b > a else { continue }
                    try panelTrack?.insertTimeRange(CMTimeRange(start: piece.range.start + (a - piece.at), end: piece.range.start + (b - piece.at)),
                                                    of: sourceVideo, at: a)
                }
            }
        }

        var audioMix: AVAudioMix?
        let audioAsset = input.audioURL.map { AVURLAsset(url: $0) } ?? videoAsset
        if let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            // Cut audio on exactly the same ranges as video so the tracks line up.
            let audioDuration = try await audioAsset.load(.duration)
            for piece in pieces {
                let audioRange = audioDuration >= piece.range.end ? piece.range : CMTimeRange(start: piece.range.start, end: audioDuration)
                if audioRange.duration > .zero {
                    try? audioTrack.insertTimeRange(audioRange, of: sourceAudio, at: piece.at)
                }
            }
            if pieces.count > 1 {
                // A few milliseconds of fade on each side of the cut keeps it from clicking.
                let params = AVMutableAudioMixInputParameters(track: audioTrack)
                let fade = CMTime(value: 30, timescale: 1000)
                for piece in pieces.dropFirst() {
                    params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: piece.at - fade, duration: fade))
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: piece.at, duration: fade))
                }
                let mix = AVMutableAudioMix()
                mix.inputParameters = [params]
                audioMix = mix
            }
        }
        // The composition lasts as long as its longest track. Audio and video can round to slightly
        // different lengths; the video instruction must cover every frame of it, or AVFoundation rejects
        // the composition (export fails with -11841 and the preview stays black).
        let total = composition.duration

        let (sourceSize, baseTransform) = try await sourceGeometry(sourceVideo)
        let renderSize = input.aspect.renderSize(shortSide: input.shortSide)
        let fps = Double(try await sourceVideo.load(.nominalFrameRate))
        let frameRate = fps > 1 ? min(max(fps.rounded(), 24), 60) : 30

        func transform(at sourceTime: Double) -> CGAffineTransform {
            let kf = Framing.sample(input.keyframes, at: sourceTime)
            let crop = Framing.cropRect(for: kf, sourceSize: sourceSize, targetRatio: input.aspect.ratio)
            let scale = renderSize.width / max(crop.width, 1)
            return baseTransform
                .concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        }

        let layers: [AVVideoCompositionLayerInstruction]
        if let plan, let panelTrack {
            layers = try await stackedLayers(plan: plan, pieces: pieces, output: output, mainTrack: videoTrack, panelTrack: panelTrack,
                                             sourceVideo: sourceVideo, renderSize: renderSize, keyframes: input.keyframes,
                                             fullTransform: transform)
        } else {
            // Each piece follows the crop keyframes of its own source time, so face tracking carries into the teaser.
            // Times are whole ticks counted from the piece's own start and kept inside it: AVFoundation throws if a
            // transform lands inside the previous piece's last ramp, and CMTime(seconds:) truncates rather than rounds.
            var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: videoTrack)
            for piece in pieces {
                let start = piece.segment.start, end = piece.segment.end
                let pieceEnd = piece.at + piece.range.duration
                func at(_ t: Double) -> CMTime { min(piece.at + ticks(t - start), pieceEnd) }
                var times = [start] + input.keyframes.map(\.time).filter { $0 > start && $0 < end } + [end]
                times = Array(Set(times)).sorted()
                if times.count <= 2 && input.keyframes.count <= 1 {
                    layer.setTransform(transform(at: start), at: piece.at)
                    continue
                }
                for (a, b) in zip(times, times.dropFirst()) {
                    let r = CMTimeRange(start: at(a), end: at(b))
                    guard r.duration > .zero else { continue }
                    let ta = transform(at: a), tb = transform(at: b)
                    if ta == tb {
                        layer.setTransform(ta, at: r.start)
                    } else {
                        layer.addTransformRamp(.init(timeRange: r, start: ta, end: tb))
                    }
                }
            }
            layers = [AVVideoCompositionLayerInstruction(configuration: layer)]
        }
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            backgroundColor: CGColor(gray: 0, alpha: 1),
            layerInstructions: layers,
            timeRange: CMTimeRange(start: .zero, duration: total)))

        let built = BuiltComposition(composition: composition, renderSize: renderSize,
                                     frameDuration: CMTime(value: 1, timescale: CMTimeScale(frameRate)),
                                     instruction: instruction, duration: total.seconds, audioMix: audioMix)
        // Catch an invalid composition here with a clear message instead of a black preview.
        let valid = built.videoComposition().isValid(for: composition.tracks, assetDuration: total,
                                                     timeRange: CMTimeRange(start: .zero, duration: total), validationDelegate: nil)
        guard valid else { throw RenderError.invalidComposition }
        return built
    }

    /// Layer instructions for the two-speaker layout. Where the plan stacks, the main track shows the left speaker
    /// in the top half and the panel track the right speaker in the bottom half, each cropped to its own speaker.
    /// Elsewhere the main track shows the clip's ordinary full-frame crop, following its keyframes.
    private static func stackedLayers(plan: [LayoutSegment], pieces: [(segment: ClipSegment, range: CMTimeRange, at: CMTime)],
                                      output: ((Double, (segment: ClipSegment, range: CMTimeRange, at: CMTime)) -> CMTime),
                                      mainTrack: AVMutableCompositionTrack, panelTrack: AVMutableCompositionTrack,
                                      sourceVideo: AVAssetTrack, renderSize: CGSize, keyframes: [FrameKeyframe],
                                      fullTransform: (Double) -> CGAffineTransform) async throws -> [AVVideoCompositionLayerInstruction] {
        let (sourceSize, baseTransform) = try await sourceGeometry(sourceVideo)
        let natural = try await sourceVideo.load(.naturalSize)
        let wholeFrame = CGRect(origin: .zero, size: natural)
        let half = renderSize.height / 2
        let panelRatio = renderSize.width / half
        // Crop rectangles are in the track's own coordinates, before its orientation transform.
        let toNatural = baseTransform.inverted()

        func panel(_ face: FaceSpot, _ other: FaceSpot, anchor: Double, y: CGFloat) -> (crop: CGRect, transform: CGAffineTransform) {
            let crop = TwoSpeaker.panelCrop(face: face, other: other, anchor: anchor, sourceSize: sourceSize, panelRatio: panelRatio)
            let scale = renderSize.width / max(crop.width, 1)
            let transform = baseTransform
                .concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: 0, y: y))
            // The top panel reaches two output pixels past the seam, so rounding never leaves a dark line between them.
            var shown = crop
            if y == 0 { shown.size.height += 2 / scale }
            return (shown.applying(toNatural), transform)
        }
        func layout(at t: Double) -> StackLayout {
            plan.first { t >= $0.start && t < $0.end }?.layout ?? .full
        }

        var main = AVVideoCompositionLayerInstruction.Configuration(assetTrack: mainTrack)
        var lower = AVVideoCompositionLayerInstruction.Configuration(assetTrack: panelTrack)
        for piece in pieces {
            let start = piece.segment.start, end = piece.segment.end
            // Every keyframe and every layout change inside the piece starts its own stretch, so stretches never overlap.
            let inside = (keyframes.map(\.time) + plan.flatMap { [$0.start, $0.end] }).filter { $0 > start && $0 < end }
            let times = Array(Set([start, end] + inside)).sorted()
            for (a, b) in zip(times, times.dropFirst()) {
                let r = CMTimeRange(start: output(a, piece), end: output(b, piece))
                guard r.duration > .zero else { continue }
                switch layout(at: (a + b) / 2) {
                case .stacked(let top, let bottom):
                    let upper = panel(top, bottom, anchor: TwoSpeaker.topAnchor, y: 0)
                    let below = panel(bottom, top, anchor: TwoSpeaker.bottomAnchor, y: half)
                    main.setCropRectangle(upper.crop, at: r.start)
                    main.setTransform(upper.transform, at: r.start)
                    lower.setCropRectangle(below.crop, at: r.start)
                    lower.setTransform(below.transform, at: r.start)
                case .full:
                    main.setCropRectangle(wholeFrame, at: r.start)
                    let ta = fullTransform(a), tb = fullTransform(b)
                    if ta == tb {
                        main.setTransform(ta, at: r.start)
                    } else {
                        main.addTransformRamp(.init(timeRange: r, start: ta, end: tb))
                    }
                }
            }
        }
        // The top panel is listed first so it sits above the lower one at the seam.
        return [AVVideoCompositionLayerInstruction(configuration: main), AVVideoCompositionLayerInstruction(configuration: lower)]
    }
}

// MARK: - Overlay

nonisolated enum CaptionTimeline {
    /// Groups clip-relative words into caption chunks, breaking at sentence ends and pauses.
    static func chunks(_ words: [Word], perChunk: Int) -> [[Word]] {
        var result: [[Word]] = []
        var current: [Word] = []
        let maxPerChunk = max(1, perChunk)
        for w in words {
            if let last = current.last, w.start - last.end > 0.7 {
                result.append(current); current = []
            }
            current.append(w)
            let endsSentence = w.text.last.map { ".?!…,".contains($0) } ?? false
            if current.count >= maxPerChunk || (endsSentence && current.count >= max(1, maxPerChunk / 2)) {
                result.append(current); current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// A finished overlay on its way from the thread that drew it to the main thread. Nothing else holds the layer.
nonisolated struct BuiltOverlay: @unchecked Sendable {
    let layer: CALayer
}

nonisolated enum OverlayBuilder {
    /// Draws the overlay away from the main thread: a long clip means hundreds of text bitmaps, which would make
    /// sliders and typing stutter. Explicit transaction, as there's no run loop here to commit an implicit one.
    @concurrent
    static func buildInBackground(_ input: RenderInput, renderSize: CGSize, duration: Double) async -> BuiltOverlay {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        return BuiltOverlay(layer: build(input, renderSize: renderSize, duration: duration))
    }

    /// Wraps overlay time so 0 means the first frame of the clip.
    private static func begin(_ t: Double) -> CFTimeInterval {
        t <= 0 ? AVCoreAnimationBeginTimeAtZero : CFTimeInterval(t)
    }

    private static func visible(from a: Double, to b: Double) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1
        anim.toValue = 1
        anim.beginTime = begin(a)
        anim.duration = max(0.01, b - a)
        anim.isRemovedOnCompletion = false
        anim.fillMode = .removed
        return anim
    }

    /// Where the hook title's bitmap goes, bottom-left origin. The drawing (not the transparent room around it)
    /// is kept inside a small margin, so position 0 reaches the top of the frame and 1 the bottom.
    static func hookFrame(imageSize: CGSize, style: HookStyle, frameSize: CGSize) -> CGRect {
        let W = frameSize.width, H = frameSize.height
        let room = TextRenderer.hookRoom(style: style, frameWidth: W)
        let margin = min(W, H) * 0.04
        let half = max(imageSize.height / 2 - room, 0)
        let top = margin + half, bottom = H - margin - half
        let fromTop = top < bottom ? min(max(H * CGFloat(style.positionY), top), bottom) : H / 2
        let x = style.look.leading ? W * 0.06 - room : (W - imageSize.width) / 2
        return CGRect(x: x, y: H - fromTop - imageSize.height / 2, width: imageSize.width, height: imageSize.height)
    }

    /// Builds a layer in output pixels with a bottom-left origin.
    static func build(_ input: RenderInput, renderSize: CGSize, duration: Double) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        root.isGeometryFlipped = false
        let W = renderSize.width, H = renderSize.height

        // B-roll, under the captions so the words stay readable.
        let timeline = input.timeline
        for insert in input.broll {
            // Cards belong to the clip itself, never to the teaser.
            let a = timeline.output(forSource: insert.time)
            let b = min(a + insert.duration, duration)
            let start = max(timeline.teaserDuration, a)
            guard b - start > 0.3,
                  let art = BRollRenderer.art(for: insert, source: input.brollSources[insert.id], input: input, renderSize: renderSize)
            else { continue }
            let container = CALayer()
            container.frame = art.frame
            container.opacity = 0
            container.add(visible(from: start, to: b), forKey: "visible")
            let card = CALayer()
            card.frame = container.bounds
            card.contents = art.poses[0]
            if art.poses.count > 1 {
                // Stop-motion: alternate between slightly different poses.
                let flip = CAKeyframeAnimation(keyPath: "contents")
                flip.values = art.poses
                flip.calculationMode = .discrete
                flip.duration = BRollRenderer.poseSeconds * Double(art.poses.count)
                flip.repeatCount = Float((b - start) / flip.duration) + 1
                flip.beginTime = begin(start)
                flip.isRemovedOnCompletion = false
                flip.fillMode = .removed
                card.add(flip, forKey: "poses")
            }
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = insert.kind == .full ? 1.08 : 0.35
            pop.toValue = 1
            pop.damping = insert.kind == .full ? 16 : 11
            pop.stiffness = 380
            pop.mass = 0.7
            pop.beginTime = begin(start)
            pop.duration = 0.4
            pop.isRemovedOnCompletion = false
            pop.fillMode = .removed
            card.add(pop, forKey: "pop")
            if insert.kind == .overlay {
                let out = CABasicAnimation(keyPath: "opacity")
                out.fromValue = 1
                out.toValue = 0
                out.beginTime = begin(max(start, b - 0.16))
                out.duration = 0.16
                out.isRemovedOnCompletion = false
                out.fillMode = .forwards
                card.add(out, forKey: "out")
            }
            container.addSublayer(card)
            root.addSublayer(container)
        }

        // Captions
        if input.caption.enabled {
            // Captions are grouped per piece so a line never runs across the cut after the teaser.
            var timed: [(chunk: [Word], pieceStart: Double, limit: Double)] = []
            for piece in timeline.pieces {
                let pieceEnd = min(piece.offset + piece.segment.duration, duration)
                let relative = input.words
                    .filter { $0.end > piece.segment.start && $0.start < piece.segment.end }
                    .map { Word(text: $0.text, start: $0.start - piece.segment.start + piece.offset,
                                end: min($0.end - piece.segment.start + piece.offset, pieceEnd)) }
                let chunks = CaptionTimeline.chunks(relative, perChunk: input.caption.wordsPerChunk)
                for (ci, chunk) in chunks.enumerated() {
                    timed.append((chunk, piece.offset, ci + 1 < chunks.count ? chunks[ci + 1].first!.start : pieceEnd))
                }
            }
            let centerY = H * (1 - CGFloat(input.caption.positionY))
            for (chunk, pieceStart, limit) in timed {
                guard let first = chunk.first, let last = chunk.last else { continue }
                let chunkStart = max(pieceStart, first.start)
                let chunkEnd = min(max(last.end + 0.25, chunkStart + 0.3), limit, duration)
                guard chunkEnd > chunkStart else { continue }
                let texts = chunk.map(\.text)
                let container = CALayer()
                var states: [(CGImage, Double, Double)] = []
                if input.caption.highlight == .none {
                    if let img = TextRenderer.caption(words: texts, active: nil, style: input.caption, frameWidth: W) {
                        states.append((img, chunkStart, chunkEnd))
                    }
                } else {
                    for (wi, w) in chunk.enumerated() {
                        let a = wi == 0 ? chunkStart : max(chunkStart, w.start)
                        let b = wi + 1 < chunk.count ? max(a + 0.01, chunk[wi + 1].start) : chunkEnd
                        guard b > a, let img = TextRenderer.caption(words: texts, active: wi, style: input.caption, frameWidth: W) else { continue }
                        states.append((img, a, b))
                    }
                }
                guard let size = states.first.map({ CGSize(width: $0.0.width, height: $0.0.height) }) else { continue }
                container.frame = CGRect(x: (W - size.width) / 2, y: centerY - size.height / 2, width: size.width, height: size.height)
                for (img, a, b) in states {
                    let l = CALayer()
                    l.frame = CGRect(origin: .zero, size: size)
                    l.contents = img
                    l.opacity = 0
                    l.add(visible(from: a, to: b), forKey: "visible")
                    container.addSublayer(l)
                }
                switch input.caption.entrance {
                case .pop:
                    let pop = CASpringAnimation(keyPath: "transform.scale")
                    pop.fromValue = 0.78
                    pop.toValue = 1
                    pop.damping = 14
                    pop.stiffness = 420
                    pop.mass = 0.6
                    pop.beginTime = begin(chunkStart)
                    pop.duration = 0.3
                    pop.isRemovedOnCompletion = false
                    pop.fillMode = .removed
                    container.add(pop, forKey: "pop")
                case .rise:
                    let rise = CABasicAnimation(keyPath: "position.y")
                    rise.fromValue = container.position.y - H * 0.025
                    rise.toValue = container.position.y
                    rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    rise.beginTime = begin(chunkStart)
                    rise.duration = 0.18
                    rise.isRemovedOnCompletion = false
                    rise.fillMode = .removed
                    container.add(rise, forKey: "rise")
                case .fade:
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.beginTime = begin(chunkStart)
                    fade.duration = 0.18
                    fade.isRemovedOnCompletion = false
                    fade.fillMode = .removed
                    container.add(fade, forKey: "fade")
                case .none:
                    break
                }
                root.addSublayer(container)
            }
        }

        // Hook title
        if input.hook.enabled, !input.hookText.trimmingCharacters(in: .whitespaces).isEmpty,
           let img = TextRenderer.hook(input.hookText, style: input.hook, frameWidth: W) {
            let l = CALayer()
            l.frame = hookFrame(imageSize: CGSize(width: img.width, height: img.height), style: input.hook,
                                frameSize: CGSize(width: W, height: H))
            l.contents = img
            l.opacity = 0
            // With a teaser, the hook stays over it and still gets its full time in the clip.
            let shown = input.hook.duration <= 0 ? duration : min(duration, input.hook.duration + timeline.teaserDuration)
            l.add(visible(from: 0, to: shown), forKey: "visible")
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.85
            pop.toValue = 1
            pop.damping = 12
            pop.stiffness = 300
            pop.beginTime = AVCoreAnimationBeginTimeAtZero
            pop.duration = 0.45
            pop.isRemovedOnCompletion = false
            pop.fillMode = .removed
            l.add(pop, forKey: "pop")
            root.addSublayer(l)
        }

        // Watermark
        let wm = input.watermark
        if wm.enabled {
            var image: CGImage?
            if wm.useImage, !wm.imagePath.isEmpty { image = TextRenderer.image(at: wm.imagePath) }
            if image == nil, !wm.text.isEmpty { image = TextRenderer.watermarkText(wm.text, frameWidth: W, size: wm.size) }
            if let image {
                var size = CGSize(width: image.width, height: image.height)
                if wm.useImage {
                    let targetW = W * CGFloat(wm.size)
                    size = CGSize(width: targetW, height: targetW * size.height / max(size.width, 1))
                }
                let m = W * 0.05
                let origin: CGPoint = switch wm.position {
                case .topLeading: CGPoint(x: m, y: H - m * 1.6 - size.height)
                case .topTrailing: CGPoint(x: W - m - size.width, y: H - m * 1.6 - size.height)
                case .bottomLeading: CGPoint(x: m, y: m * 1.6)
                case .bottomTrailing: CGPoint(x: W - m - size.width, y: m * 1.6)
                case .center: CGPoint(x: (W - size.width) / 2, y: (H - size.height) / 2)
                }
                let l = CALayer()
                l.frame = CGRect(origin: origin, size: size)
                l.contents = image
                l.contentsGravity = .resizeAspect
                l.opacity = Float(wm.opacity)
                root.addSublayer(l)
            }
        }
        return root
    }
}

// MARK: - Export

nonisolated enum ClipExporter {
    @concurrent
    static func export(_ input: RenderInput, to url: URL, hevc: Bool,
                       progress: @Sendable @escaping (Double) -> Void) async throws {
        let input = await BRollRenderer.prepare(input)
        let built = try await CompositionBuilder.build(input)
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: built.renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        parent.addSublayer(OverlayBuilder.build(input, renderSize: built.renderSize, duration: built.duration))
        let tool = AVVideoCompositionCoreAnimationTool(configuration: .init(postProcessingAsVideoLayer: videoLayer, containingLayer: parent))

        let preset = hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw RenderError.exportFailed(String(localized: "macOS couldn’t start an export for this clip."))
        }
        session.videoComposition = built.videoComposition(animationTool: tool)
        session.audioMix = built.audioMix
        session.shouldOptimizeForNetworkUse = true

        // Rendered beside the final file and moved into place only once it's checked, so a failed or cancelled
        // export never damages an earlier export of this clip or leaves half a video behind.
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appending(path: ".\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: partial) }
        // The session reports its own state from any thread; the watcher only reads it.
        nonisolated(unsafe) let watched = session
        let watcher = Task {
            for await state in watched.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: partial, as: .mp4)
        try await verify(partial, expectedDuration: input.timeline.duration)
        try AppPaths.replace(url, with: partial)
        progress(1)
    }

    /// Confirms a rendered file really contains playable video of about the right length.
    static func verify(_ url: URL, expectedDuration: Double) async throws {
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard playable, !tracks.isEmpty, duration > max(0.5, expectedDuration * 0.8) else {
            throw RenderError.exportFailed(String(localized: "the finished file has no playable video (length \(formatDuration(duration))). Please export again."))
        }
    }

    /// Saves the first frame of a finished video as a JPEG, captions and hook included, replacing `url` in one step.
    @concurrent
    static func saveFirstFrame(of video: URL, to url: URL) async throws {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: .zero)
        let partial = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: partial) }
        try writeJPEG(image, to: partial, quality: 0.92)
        try AppPaths.replace(url, with: partial)
    }

    /// A still of the reframed clip, without overlays, saved as JPEG.
    @concurrent
    static func thumbnail(_ input: RenderInput, to url: URL, at offset: Double = 1.0) async throws {
        let built = try await CompositionBuilder.build(input)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition()
        generator.maximumSize = CGSize(width: 540, height: 960)
        let (image, _) = try await generator.image(at: CMTime(seconds: min(offset, built.duration / 2), preferredTimescale: 600))
        try writeJPEG(image, to: url)
    }

    /// One reframed frame of a stretch of the source, without overlays.
    @concurrent
    static func frame(_ input: RenderInput, at offset: Double, maxSize: CGSize) async throws -> CGImage {
        let built = try await CompositionBuilder.build(input)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition()
        generator.maximumSize = maxSize
        let (image, _) = try await generator.image(at: CMTime(seconds: min(offset, built.duration / 2), preferredTimescale: 600))
        return image
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.82) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RenderError.imageNotWritten
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.imageNotWritten }
    }
}
