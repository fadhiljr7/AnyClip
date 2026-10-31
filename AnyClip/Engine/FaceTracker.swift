//
//  FaceTracker.swift
//  AnyClip
//
//  Samples frames, finds the main speaker's face with Vision and turns the
//  positions into a small set of camera keyframes: steady holds, gentle pans
//  and hard cuts when the speaker changes. It also keeps every face it saw
//  and the exact camera cuts, which the two-speaker layout plans from.
//

import Foundation
import AVFoundation
import Vision

nonisolated struct FaceTrack: Sendable {
    var keyframes: [FrameKeyframe]
    /// Every face seen and the camera cuts, for the two-speaker layout; nil when the source couldn't be read
    /// or is already narrower than the target.
    var shots: ShotAnalysis?
}

nonisolated enum FaceTracker {
    /// Keyframes for `range`, plus what each sampled frame shows. The same frames serve both, so keeping the
    /// faces costs nothing extra; only camera cuts are looked at again, a few frames each, to find the exact frame.
    @concurrent
    static func analyze(video: URL, range: ClosedRange<Double>, aspect: AspectRatio,
                        samplesPerSecond: Double = 3) async -> FaceTrack {
        let fallback = FaceTrack(keyframes: [.centered(at: range.lowerBound)], shots: nil)
        let asset = AVURLAsset(url: video)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else {
            return fallback
        }
        let oriented = CGRect(origin: .zero, size: natural).applying(transform).size
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        // Nothing to pan when the source is already narrower than the target.
        guard size.width / max(size.height, 1) > aspect.ratio * 1.05 else {
            return fallback
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let tolerance = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let step = 1 / samplesPerSecond
        let times = stride(from: range.lowerBound, through: range.upperBound, by: step)
            .map { CMTime(seconds: $0, preferredTimescale: 600) }
        let request = DetectFaceRectanglesRequest()
        var samples: [(time: Double, x: Double?, y: Double?)] = []
        var seen: [(sample: ShotSample, signature: [UInt8])] = []
        var previous: Double?

        for await result in generator.images(for: times) {
            if Task.isCancelled { break }
            let t = result.requestedTime.seconds
            guard let image = try? result.image else { samples.append((t, nil, nil)); continue }
            let faces = (try? await request.perform(on: image)) ?? []
            // Prefer the biggest face; break ties toward where we were.
            let best = faces.max { a, b in
                score(a.boundingBox, previous: previous) < score(b.boundingBox, previous: previous)
            }
            if let best {
                let box = best.boundingBox
                let cx = box.origin.x + box.width / 2
                let cy = 1 - (box.origin.y + box.height * 0.65)   // Vision is bottom-left; bias up to keep eyes high
                samples.append((t, cx, cy))
                previous = cx
            } else {
                samples.append((t, nil, nil))
            }
            let spots = faces.map { f in
                let b = f.boundingBox
                return FaceSpot(x: b.origin.x + b.width / 2, y: 1 - (b.origin.y + b.height / 2), width: b.width, height: b.height)
            }
            seen.append((ShotSample(time: (try? result.actualTime.seconds) ?? t, faces: spots), signature(image)))
        }
        let keyframes = keyframes(from: samples.sorted { $0.time < $1.time }, range: range, size: size, aspect: aspect)
        guard !Task.isCancelled, !seen.isEmpty else { return FaceTrack(keyframes: keyframes, shots: nil) }

        seen.sort { $0.sample.time < $1.sample.time }
        let cutsStarted = Date()
        let fps = Double((try? await track.load(.nominalFrameRate)) ?? 30)
        var cuts: [Double] = []
        var exact = 0
        for (a, b) in zip(seen, seen.dropFirst()) where difference(a.signature, b.signature) > cutChange {
            // Finding the exact frame means decoding again, so it's only done where the layout may change at the cut.
            // Elsewhere halfway between the two frames is close enough: it only separates shots.
            guard TwoSpeaker.layoutMayChange(from: a.sample.faces, to: b.sample.faces) else {
                cuts.append((a.sample.time + b.sample.time) / 2)
                continue
            }
            exact += 1
            if let cut = await cutTime(asset: asset, after: a.sample.time, through: b.sample.time, frameRate: fps > 1 ? fps : 30) {
                cuts.append(cut)
            }
        }
        engineLog(String(format: "faces: %d frames, %d cuts (%d placed exactly) in %.2f s", seen.count, cuts.count, exact,
                         Date().timeIntervalSince(cutsStarted)))
        let shots = ShotAnalysis(samples: seen.map(\.sample), cuts: cuts,
                                 analyzed: ClipSegment(start: range.lowerBound, end: range.upperBound))
        return FaceTrack(keyframes: keyframes, shots: shots)
    }

    // MARK: Camera cuts

    /// Change between two sampled frames (a third of a second apart) that may be a cut. Ordinary movement in a
    /// podcast stays under about 0.08; a cut to another camera is usually 0.14 or more.
    static let cutChange = 0.1
    /// A cut happens between two neighbouring frames; a change spread over many frames is movement or a dissolve.
    static let frameCutChange = 0.06

    /// A 16×9 grey thumbnail, enough to tell one camera shot from another.
    static func signature(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 16 * 9)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 16, height: 9, bitsPerComponent: 8, bytesPerRow: 16,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        return buffer
    }

    /// Mean difference between two signatures, 0…1.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var total = 0
        for i in a.indices { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count) / 255
    }

    /// The first frame of the new shot between two sampled frames, or nil when the change is gradual.
    private static func cutTime(asset: AVURLAsset, after a: Double, through b: Double, frameRate: Double) async -> Double? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 96, height: 96)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let times = stride(from: a, through: b, by: 1 / frameRate).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var frames: [(time: Double, signature: [UInt8])] = []
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            frames.append(((try? result.actualTime.seconds) ?? result.requestedTime.seconds, signature(image)))
        }
        frames.sort { $0.time < $1.time }
        var best: (time: Double, change: Double)?
        for (x, y) in zip(frames, frames.dropFirst()) {
            let change = difference(x.signature, y.signature)
            if change > (best?.change ?? 0) { best = (y.time, change) }
        }
        guard let best, best.change >= frameCutChange else { return nil }
        return best.time
    }

    private static func score(_ box: NormalizedRect, previous: Double?) -> Double {
        let area = box.width * box.height
        guard let previous else { return area }
        let cx = box.origin.x + box.width / 2
        return area * (1.4 - min(abs(cx - previous), 1))
    }

    static func keyframes(from samples: [(time: Double, x: Double?, y: Double?)], range: ClosedRange<Double>,
                          size: CGSize, aspect: AspectRatio) -> [FrameKeyframe] {
        // Fill gaps by holding the last known position.
        var filled: [(Double, Double, Double)] = []
        var lastX = samples.first(where: { $0.x != nil })?.x ?? 0.5
        var lastY = samples.first(where: { $0.y != nil })?.y ?? 0.5
        for s in samples {
            if let x = s.x { lastX = x }
            if let y = s.y { lastY = y }
            filled.append((s.time, lastX, lastY))
        }
        guard !filled.isEmpty else { return [.centered(at: range.lowerBound)] }

        // Median filter removes single-frame detection glitches.
        let xs = filled.map(\.1), ys = filled.map(\.2)
        func median(_ arr: [Double], _ i: Int) -> Double {
            let lo = max(0, i - 2), hi = min(arr.count - 1, i + 2)
            let window = arr[lo...hi].sorted()
            return window[window.count / 2]
        }
        let smoothX = xs.indices.map { median(xs, $0) }
        let smoothY = ys.indices.map { median(ys, $0) }

        // How far the crop can move, in normalised units, before it hits the edge.
        let cropWidthFraction = min(1, (size.height * aspect.ratio) / size.width)
        let deadZone = cropWidthFraction * 0.18
        let cutThreshold = cropWidthFraction * 0.6

        var result: [FrameKeyframe] = [FrameKeyframe(time: range.lowerBound, cx: smoothX[0], cy: smoothY[0].clamped(to: 0.3...0.6))]
        var anchor = smoothX[0]
        for i in 1..<filled.count {
            let t = filled[i].0, x = smoothX[i]
            let delta = x - anchor
            guard abs(delta) > deadZone else { continue }
            // Require the new position to be stable for ~0.6 s to avoid chasing gestures.
            let ahead = smoothX[i..<min(smoothX.count, i + 2)]
            guard ahead.allSatisfy({ abs($0 - x) < deadZone }) else { continue }
            let prev = result[result.count - 1]
            let y = smoothY[i].clamped(to: 0.3...0.6)
            if abs(delta) > cutThreshold {
                // Speaker change: hold, then cut.
                result.append(FrameKeyframe(time: max(prev.time, t - 0.04), cx: prev.cx, cy: prev.cy))
                result.append(FrameKeyframe(time: t, cx: x, cy: y))
            } else {
                result.append(FrameKeyframe(time: max(prev.time, t - 0.7), cx: prev.cx, cy: prev.cy))
                result.append(FrameKeyframe(time: t, cx: x, cy: y))
            }
            anchor = x
        }
        // Drop keyframes that collapse onto each other.
        var cleaned: [FrameKeyframe] = []
        for kf in result {
            if let last = cleaned.last, kf.time - last.time < 0.02, abs(kf.cx - last.cx) < 0.001 { continue }
            cleaned.append(kf)
        }
        return cleaned
    }
}
