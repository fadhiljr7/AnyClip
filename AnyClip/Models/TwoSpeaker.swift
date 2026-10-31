//
//  TwoSpeaker.swift
//  AnyClip
//
//  The two-speaker stacked layout: one speaker above the other in a vertical
//  clip. Face tracking already looks at a few frames per second of every clip;
//  it keeps every face it sees and the exact times of camera cuts, and this
//  file turns that record into a per-clip verdict and a layout plan. The plan
//  stacks only shots where both speakers are really in frame and shows the
//  other shots full-frame, so a speaker who isn't in the source is never
//  invented.
//

import Foundation
import CoreGraphics

/// A face in a sampled frame, normalised to the oriented source frame with a top-left origin.
nonisolated struct FaceSpot: Codable, Hashable, Sendable {
    /// Centre.
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

nonisolated struct ShotSample: Codable, Hashable, Sendable {
    /// Source time of the frame that was actually looked at.
    var time: Double
    var faces: [FaceSpot]
}

/// What face tracking saw in a clip, saved so the layout can be judged and planned without decoding the video again.
nonisolated struct ShotAnalysis: Codable, Hashable, Sendable {
    var samples: [ShotSample]
    /// Exact source times of camera cuts, at the first frame of the new shot.
    var cuts: [Double]
    /// The source range that was looked at.
    var analyzed: ClipSegment
}

/// What one sampled frame shows.
nonisolated enum SpeakerView: Equatable, Sendable {
    /// Two speakers side by side, both fully in frame.
    case both(left: FaceSpot, right: FaceSpot)
    /// One speaker fills the shot, e.g. a close-up.
    case one(FaceSpot)
    /// No usable face, a group, or graphics.
    case unclear
}

/// Per-clip result. An estimate from the faces found, not a guarantee.
nonisolated enum StackSuitability: Equatable, Sendable {
    /// Both speakers are visible for (nearly) the whole clip.
    case suitable
    /// Both speakers are visible part of the time; the rest is shown full-frame.
    case mixed(share: Double)
    /// Only one speaker is on screen at a time: a solo talk, or a podcast that cuts between close-ups.
    case oneSpeaker
    /// Faces couldn't be found reliably: graphics, low light, faces turned away, or more than two people.
    case insufficient

    var allowsStacking: Bool {
        switch self {
        case .suitable, .mixed: true
        case .oneSpeaker, .insufficient: false
        }
    }
}

nonisolated enum StackLayout: Hashable, Sendable {
    /// `top` is the speaker on the left of the source and `bottom` the one on the right, unless the clip swaps them.
    case stacked(top: FaceSpot, bottom: FaceSpot)
    /// The clip's own crop keyframes, as without the stacked layout.
    case full
}

/// A stretch of the clip in source time and how it is laid out.
nonisolated struct LayoutSegment: Hashable, Sendable {
    var start: Double
    var end: Double
    var layout: StackLayout

    var isStacked: Bool { if case .stacked = layout { true } else { false } }

    /// The same stretch with the two panels the other way round. A full-frame stretch stays as it is.
    var swapped: LayoutSegment {
        guard case .stacked(let top, let bottom) = layout else { return self }
        return LayoutSegment(start: start, end: end, layout: .stacked(top: bottom, bottom: top))
    }
}

nonisolated enum TwoSpeaker {
    /// Faces smaller than this share of the frame height are ignored: background people, photos, noise.
    static let minFace = 0.06
    /// A lone face must be at least this big to count as a single-speaker shot.
    static let minSingleFace = 0.08
    /// How far in from the left and right edges a face's box must be to count as a whole speaker.
    static let edgeMargin = 0.02
    static let minSeparation = 0.2
    /// Two faces this different in size are a close-up with someone in the foreground, not a two-shot.
    static let maxSizeRatio = 1.7
    /// Frames at the start of a shot that decide how it opens, about a second at 3 per second.
    static let openingSamples = 3
    /// Readable frames in a row needed before the layout changes without a camera cut, about two seconds. A head
    /// turned away for a moment isn't a new shot; a graphic covering a speaker for several seconds is.
    static let holdSamples = 6
    static let suitableShare = 0.9
    /// Below this, a few stacked seconds aren't worth a layout that keeps switching.
    static let minStackedShare = 0.15

    // MARK: Classifying a frame

    static func view(of faces: [FaceSpot]) -> SpeakerView {
        let sized = faces.filter { $0.height >= minFace }.sorted { $0.height > $1.height }
        // A face cut off by the frame edge is someone outside the shot, not a second speaker.
        let whole = sized.filter { $0.x - $0.width / 2 >= edgeMargin && $0.x + $0.width / 2 <= 1 - edgeMargin }
        if whole.count >= 3, whole[2].height >= whole[1].height * 0.6 { return .unclear }
        if whole.count >= 2 {
            let a = whole[0], b = whole[1]
            if abs(a.x - b.x) > minSeparation, a.height / b.height < maxSizeRatio {
                return a.x < b.x ? .both(left: a, right: b) : .both(left: b, right: a)
            }
        }
        if let biggest = sized.first, biggest.height >= minSingleFace { return .one(biggest) }
        return .unclear
    }

    // MARK: Planning a clip

    /// How a clip's range is laid out. Each camera shot is judged on its own; inside a shot the layout only changes
    /// after `holdSamples` frames agree, so a missed face or a passing hand doesn't make it flicker. Shots with
    /// no usable faces, and anything outside the analysed range, use the full-frame layout.
    static func segments(_ analysis: ShotAnalysis, range: ClipSegment) -> [LayoutSegment] {
        let lo = range.start, hi = range.end
        guard hi > lo else { return [] }
        let checkedLo = max(lo, analysis.analyzed.start), checkedHi = min(hi, analysis.analyzed.end)
        var result: [LayoutSegment] = []
        if checkedHi > checkedLo {
            let bounds = [checkedLo] + analysis.cuts.filter { $0 > checkedLo + 0.01 && $0 < checkedHi - 0.01 }.sorted() + [checkedHi]
            for (a, b) in zip(bounds, bounds.dropFirst()) {
                let samples = analysis.samples.filter { $0.time >= a && $0.time < b }
                result += shotSegments(samples, start: a, end: b)
            }
        }
        if checkedHi <= checkedLo {
            result = [LayoutSegment(start: lo, end: hi, layout: .full)]
        } else {
            if checkedLo > lo { result.insert(LayoutSegment(start: lo, end: checkedLo, layout: .full), at: 0) }
            if checkedHi < hi { result.append(LayoutSegment(start: checkedHi, end: hi, layout: .full)) }
        }
        return merged(result)
    }

    /// Layout inside one camera shot.
    private static func shotSegments(_ samples: [ShotSample], start: Double, end: Double) -> [LayoutSegment] {
        let views = samples.map { (time: $0.time, view: view(of: $0.faces)) }
        // true = both visible, false = one speaker, nil = can't tell.
        func state(_ v: SpeakerView) -> Bool? {
            switch v {
            case .both: true
            case .one: false
            case .unclear: nil
            }
        }
        let opening = views.compactMap { state($0.view) }.prefix(openingSamples)
        guard let first = views.firstIndex(where: { state($0.view) != nil }) else {
            return [LayoutSegment(start: start, end: end, layout: .full)]
        }
        // The shot opens with what most of its first frames show, so one missed face at a cut doesn't decide it.
        let opensStacked = opening.filter { $0 }.count * 2 > opening.count
        // Runs of the confirmed state, with switch points halfway between the last frame of one and the first of the next.
        var runs: [(start: Double, stacked: Bool, from: Int)] = [(start, opensStacked, 0)]
        var i = first + 1
        while i < views.count {
            let current = runs[runs.count - 1].stacked
            if let s = state(views[i].view), s != current {
                // Only a change that holds for the next few readable frames counts; near the end of a shot there
                // aren't enough left to be sure, so the layout stays as it is.
                let ahead = Array(views[i...].lazy.compactMap { state($0.view) }.prefix(holdSamples))
                let confirmed = ahead.count == holdSamples && ahead.allSatisfy { $0 == s }
                if confirmed {
                    let at = (views[i - 1].time + views[i].time) / 2
                    runs.append((at, s, i))
                    i += holdSamples
                    continue
                }
            }
            i += 1
        }
        var out: [LayoutSegment] = []
        for (k, run) in runs.enumerated() {
            let runEnd = k + 1 < runs.count ? runs[k + 1].start : end
            let upto = k + 1 < runs.count ? runs[k + 1].from : views.count
            guard runEnd > run.start else { continue }
            if run.stacked {
                let pairs = views[run.from..<upto].compactMap { v -> (FaceSpot, FaceSpot)? in
                    if case .both(let l, let r) = v.view { return (l, r) } else { return nil }
                }
                if let top = median(pairs.map(\.0)), let bottom = median(pairs.map(\.1)) {
                    out.append(LayoutSegment(start: run.start, end: runEnd, layout: .stacked(top: top, bottom: bottom)))
                    continue
                }
            }
            out.append(LayoutSegment(start: run.start, end: runEnd, layout: .full))
        }
        return out
    }

    /// Joins neighbours with the same layout. Stacked neighbours are joined only when the speakers sit in the same
    /// place, so a cut to a different camera angle reframes, but a falsely detected cut doesn't nudge the crop.
    private static func merged(_ segments: [LayoutSegment]) -> [LayoutSegment] {
        var out: [LayoutSegment] = []
        for seg in segments where seg.end > seg.start {
            if let last = out.last {
                switch (last.layout, seg.layout) {
                case (.full, .full):
                    out[out.count - 1].end = seg.end
                    continue
                case (.stacked(let t1, let b1), .stacked(let t2, let b2)) where close(t1, t2) && close(b1, b2):
                    out[out.count - 1].end = seg.end
                    continue
                default: break
                }
            }
            out.append(seg)
        }
        return out
    }

    /// Whether a camera cut between two frames could change the layout: stacked on one side and not the other, or
    /// stacked on both with the speakers in different places.
    static func layoutMayChange(from a: [FaceSpot], to b: [FaceSpot]) -> Bool {
        switch (view(of: a), view(of: b)) {
        case (.both(let l1, let r1), .both(let l2, let r2)): !(close(l1, l2) && close(r1, r2))
        case (.both, _), (_, .both): true
        default: false
        }
    }

    static func close(_ a: FaceSpot, _ b: FaceSpot) -> Bool {
        abs(a.x - b.x) < 0.03 && abs(a.y - b.y) < 0.03 && abs(a.height - b.height) < max(a.height, b.height) * 0.15
    }

    private static func median(_ spots: [FaceSpot]) -> FaceSpot? {
        guard !spots.isEmpty else { return nil }
        func mid(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
        return FaceSpot(x: mid(spots.map(\.x)), y: mid(spots.map(\.y)), width: mid(spots.map(\.width)), height: mid(spots.map(\.height)))
    }

    // MARK: Verdict

    static func suitability(_ analysis: ShotAnalysis, range: ClipSegment) -> StackSuitability {
        let samples = analysis.samples.filter { $0.time >= range.start && $0.time <= range.end }
        guard !samples.isEmpty, range.duration > 0 else { return .insufficient }
        let segs = segments(analysis, range: range)
        let stackedSeconds: Double = segs.filter(\.isStacked).map { $0.end - $0.start }.reduce(0, +)
        let stacked = stackedSeconds / range.duration
        if stacked >= suitableShare { return .suitable }
        if stacked >= minStackedShare { return .mixed(share: stacked) }
        let singles = samples.filter { if case .one = view(of: $0.faces) { true } else { false } }.count
        return Double(singles) / Double(samples.count) >= 0.5 ? .oneSpeaker : .insufficient
    }

    // MARK: Geometry

    /// Where each speaker's face sits in their panel, as a share of the panel height. The top speaker sits a little
    /// low so the hook title clears their face; the bottom one a little high so captions on the seam clear theirs.
    static let topAnchor = 0.58
    static let bottomAnchor = 0.45
    /// Panel height as a multiple of the face height: head and shoulders.
    static let faceToPanel = 3.0
    /// Caption position used while stacked: on the seam between the two panels.
    static let seamCaptionY = 0.5

    /// The source rectangle (pixels, top-left origin) shown in one panel. Both panels use the same zoom so the two
    /// speakers look the same size, and a panel is never wider than the gap between them, so it doesn't show the
    /// other speaker's face.
    static func panelCrop(face: FaceSpot, other: FaceSpot, anchor: Double, sourceSize: CGSize, panelRatio: Double) -> CGRect {
        let sw = sourceSize.width, sh = sourceSize.height
        guard sw > 0, sh > 0, panelRatio > 0 else { return .zero }
        let faceHeight = (face.height + other.height) / 2 * sh
        var h = min(max(faceHeight * faceToPanel, sh * 0.3), sh)
        var w = h * panelRatio
        let gap = abs(face.x - other.x) * sw
        if w > gap { w = gap; h = w / panelRatio }
        if w > sw { w = sw; h = w / panelRatio }
        if h > sh { h = sh; w = h * panelRatio }
        let x = min(max(face.x * sw - w / 2, 0), sw - w)
        let y = min(max(face.y * sh - anchor * h, 0), sh - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

/// Turning the layout on explains it once first; the answer is kept in the app's settings.
nonisolated enum StackedLayoutIntro {
    static let acknowledgedKey = "stackedLayoutAcknowledged"

    enum Action: Equatable {
        case apply(Bool)
        case explain
    }

    /// What a Stacked Layout switch does when flipped: turning it off always applies; turning it on shows the
    /// explanation until the user has confirmed it once.
    static func request(_ on: Bool, defaults: UserDefaults = .standard) -> Action {
        on && !defaults.bool(forKey: acknowledgedKey) ? .explain : .apply(on)
    }

    static func confirm(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: acknowledgedKey)
    }
}
