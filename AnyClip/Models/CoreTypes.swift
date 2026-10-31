//
//  CoreTypes.swift
//  AnyClip
//
//  Value types shared by the engine and the UI. Times are always seconds in
//  the *source* video's timeline unless a name says otherwise.
//

import Foundation
import CoreGraphics

// MARK: - Transcript

nonisolated struct Word: Codable, Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// A sentence-ish group of words, used to give the AI a compact, numbered transcript.
nonisolated struct TranscriptLine: Codable, Hashable, Sendable {
    var index: Int
    var start: Double
    var end: Double
    var text: String
}

nonisolated struct Transcript: Codable, Sendable {
    var language: String
    var words: [Word]

    var duration: Double { words.last?.end ?? 0 }

    func words(in range: ClosedRange<Double>) -> [Word] {
        words.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
    }

    /// Groups words into lines that end on punctuation or after `maxSeconds`.
    func lines(minSeconds: Double = 4, maxSeconds: Double = 16) -> [TranscriptLine] {
        var result: [TranscriptLine] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            result.append(TranscriptLine(index: result.count, start: first.start, end: last.end, text: text))
            current.removeAll()
        }
        for (i, word) in words.enumerated() {
            if let last = current.last, word.start - last.end > 1.2, (last.end - (current.first?.start ?? 0)) >= 1 {
                flush()
            }
            current.append(word)
            let span = word.end - (current.first?.start ?? word.start)
            let isLast = i == words.count - 1
            if isLast || (word.text.endsSentence && span >= minSeconds) || span >= maxSeconds {
                flush()
            }
        }
        flush()
        return result
    }
}

// MARK: - Framing

nonisolated enum AspectRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case vertical = "9:16"
    case square = "1:1"
    case portrait = "4:5"
    case landscape = "16:9"

    var id: String { rawValue }

    /// width / height
    var ratio: Double {
        switch self {
        case .vertical: 9.0 / 16.0
        case .square: 1
        case .portrait: 4.0 / 5.0
        case .landscape: 16.0 / 9.0
        }
    }

    func renderSize(shortSide: Double) -> CGSize {
        switch self {
        case .vertical: CGSize(width: shortSide, height: (shortSide * 16 / 9).rounded())
        case .square: CGSize(width: shortSide, height: shortSide)
        case .portrait: CGSize(width: shortSide, height: (shortSide * 5 / 4).rounded())
        case .landscape: CGSize(width: (shortSide * 16 / 9).rounded(), height: shortSide)
        }
    }

    var symbol: String {
        switch self {
        case .vertical: "rectangle.portrait"
        case .square: "square"
        case .portrait: "rectangle.portrait"
        case .landscape: "rectangle"
        }
    }
}

/// Where the crop window sits in the source frame at a moment in time.
/// `cx`/`cy` are the crop centre, normalised 0…1 with a top-left origin.
/// `zoom` 1 means the largest crop that fits; 2 shows half as much.
nonisolated struct FrameKeyframe: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var time: Double
    var cx: Double
    var cy: Double = 0.5
    var zoom: Double = 1

    static func centered(at time: Double) -> FrameKeyframe {
        FrameKeyframe(time: time, cx: 0.5)
    }
}

nonisolated enum Framing {
    /// Interpolated crop centre and zoom at `time`, holding the edge values outside the keyframes.
    static func sample(_ keyframes: [FrameKeyframe], at time: Double) -> FrameKeyframe {
        let sorted = keyframes.sorted { $0.time < $1.time }
        guard let first = sorted.first else { return .centered(at: time) }
        if time <= first.time { return first }
        guard let last = sorted.last, time < last.time else { return sorted.last ?? first }
        for (a, b) in zip(sorted, sorted.dropFirst()) where time >= a.time && time <= b.time {
            let span = max(b.time - a.time, 0.0001)
            let t = (time - a.time) / span
            return FrameKeyframe(time: time,
                                 cx: a.cx + (b.cx - a.cx) * t,
                                 cy: a.cy + (b.cy - a.cy) * t,
                                 zoom: a.zoom + (b.zoom - a.zoom) * t)
        }
        return last
    }

    /// The crop rectangle in source pixel space (top-left origin) for a keyframe.
    static func cropRect(for kf: FrameKeyframe, sourceSize: CGSize, targetRatio: Double) -> CGRect {
        let sw = sourceSize.width, sh = sourceSize.height
        guard sw > 0, sh > 0 else { return .zero }
        var cw: Double, ch: Double
        if sw / sh > targetRatio {
            ch = sh
            cw = ch * targetRatio
        } else {
            cw = sw
            ch = cw / targetRatio
        }
        let zoom = min(max(kf.zoom, 1), 4)
        cw /= zoom
        ch /= zoom
        var x = kf.cx * sw - cw / 2
        var y = kf.cy * sh - ch / 2
        x = min(max(x, 0), sw - cw)
        y = min(max(y, 0), sh - ch)
        return CGRect(x: x, y: y, width: cw, height: ch)
    }
}

/// The limits on trimming a clip. A clip keeps at least `minimumLength` seconds and stays inside its source.
nonisolated enum ClipTrim {
    static let minimumLength = 3.0

    static func start(_ wanted: Double, end: Double) -> Double {
        wanted.clamped(to: 0...max(0, end - minimumLength))
    }

    static func end(_ wanted: Double, start: Double, sourceDuration: Double) -> Double {
        let earliest = start + minimumLength
        return wanted.clamped(to: earliest...max(earliest, sourceDuration))
    }
}

// MARK: - Clip length

nonisolated enum ClipLength: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto, short, medium, long

    var id: String { rawValue }

    var range: ClosedRange<Double> {
        switch self {
        case .auto: 20...65
        case .short: 15...32
        case .medium: 30...62
        case .long: 60...95
        }
    }

    var target: Double {
        switch self {
        case .auto: 40
        case .short: 25
        case .medium: 45
        case .long: 75
        }
    }
}

// MARK: - Styles

nonisolated enum CaptionHighlight: String, Codable, CaseIterable, Identifiable, Sendable {
    case color, box, karaoke, none
    var id: String { rawValue }
}

nonisolated enum CaptionAnimation: String, Codable, CaseIterable, Identifiable, Sendable {
    case pop, rise, fade, none
    var id: String { rawValue }
}

nonisolated struct CaptionStyle: Codable, Hashable, Sendable {
    var presetID: String = "bold"
    var enabled = true
    var fontName: String = "Avenir Next"
    var fontWeight: Double = 0.62   // NSFont.Weight raw value; used when the family has a heavy face
    /// Font size as a fraction of the output frame's *width*.
    var size: Double = 0.075
    var textColor: String = "#FFFFFF"
    var highlightColor: String = "#FFD60A"
    var strokeColor: String = "#000000"
    /// Stroke width as a fraction of the font size.
    var strokeWidth: Double = 0.12
    var shadow = true
    var glow = false
    var highlight: CaptionHighlight = .color
    var entrance: CaptionAnimation = .pop
    var uppercase = true
    var wordsPerChunk = 3
    /// Vertical centre of the caption block, 0 = top, 1 = bottom.
    var positionY: Double = 0.70
}

nonisolated struct CaptionPreset: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var style: CaptionStyle

    static let all: [CaptionPreset] = [
        CaptionPreset(id: "bold", name: String(localized: "Bold"), style: CaptionStyle()),
        CaptionPreset(id: "neon", name: String(localized: "Neon"), style: CaptionStyle(
            presetID: "neon", fontName: "Futura", fontWeight: 0.4, size: 0.072,
            textColor: "#FFFFFF", highlightColor: "#5CE1FF", strokeColor: "#001018",
            strokeWidth: 0.08, shadow: false, glow: true, highlight: .color, entrance: .pop,
            uppercase: true, wordsPerChunk: 3)),
        CaptionPreset(id: "box", name: String(localized: "Box"), style: CaptionStyle(
            presetID: "box", fontName: "Avenir Next", fontWeight: 0.62, size: 0.07,
            textColor: "#FFFFFF", highlightColor: "#F2385A", strokeColor: "#000000",
            strokeWidth: 0.08, shadow: true, glow: false, highlight: .box, entrance: .rise,
            uppercase: true, wordsPerChunk: 3)),
        CaptionPreset(id: "karaoke", name: String(localized: "Karaoke"), style: CaptionStyle(
            presetID: "karaoke", fontName: "Avenir Next", fontWeight: 0.62, size: 0.066,
            textColor: "#FFFFFF", highlightColor: "#34C759", strokeColor: "#000000",
            strokeWidth: 0.11, shadow: true, glow: false, highlight: .karaoke, entrance: .none,
            uppercase: false, wordsPerChunk: 5)),
        CaptionPreset(id: "clean", name: String(localized: "Clean"), style: CaptionStyle(
            presetID: "clean", fontName: "Helvetica Neue", fontWeight: 0.3, size: 0.058,
            textColor: "#FFFFFF", highlightColor: "#FFFFFF", strokeColor: "#000000",
            strokeWidth: 0, shadow: true, glow: false, highlight: .none, entrance: .fade,
            uppercase: false, wordsPerChunk: 6, positionY: 0.78)),
        CaptionPreset(id: "impact", name: String(localized: "Impact"), style: CaptionStyle(
            presetID: "impact", fontName: "Impact", fontWeight: 0, size: 0.09,
            textColor: "#FFFFFF", highlightColor: "#FF9F0A", strokeColor: "#000000",
            strokeWidth: 0.14, shadow: false, glow: false, highlight: .color, entrance: .pop,
            uppercase: true, wordsPerChunk: 2, positionY: 0.62)),
    ]

    static func preset(_ id: String) -> CaptionPreset { all.first { $0.id == id } ?? all[0] }
}

nonisolated enum HookLook: String, Codable, CaseIterable, Identifiable, Sendable {
    case card, strip, sideAccent, outline
    var id: String { rawValue }

    var name: String {
        switch self {
        case .card: String(localized: "Card")
        case .strip: String(localized: "Highlight Strip")
        case .sideAccent: String(localized: "Side Accent")
        case .outline: String(localized: "Outline")
        }
    }

    var summary: String {
        switch self {
        case .card: String(localized: "Text on a rounded card. Clean and easy to read on any video.")
        case .strip: String(localized: "Each line on its own marker strip, like a highlighted note.")
        case .sideAccent: String(localized: "Left-aligned text beside a colored bar, like a news caption.")
        case .outline: String(localized: "Large outlined letters with no box, like a thumbnail title.")
        }
    }

    /// Side Accent sits against the left edge; the others are centred.
    var leading: Bool { self == .sideAccent }
}

/// Each look keeps its own colours, so switching looks and back doesn't lose them.
nonisolated struct HookStyle: Codable, Hashable, Sendable {
    var enabled = true
    /// Seconds the hook title stays on screen; 0 keeps it for the whole clip.
    var duration: Double = 4
    var look: HookLook = .card
    var fontName: String = "Avenir Next"
    var size: Double = 0.058
    var uppercase = false
    /// Vertical centre of the title, 0 = top, 1 = bottom; kept inside the frame when drawn.
    var positionY: Double = 0.17

    // Card
    var textColor: String = "#111111"
    var boxColor: String = "#FFFFFF"
    /// Corner radius as a fraction of the font size.
    var cornerRadius: Double = 0.45

    // Highlight Strip
    var stripTextColor: String = "#111111"
    var stripColor: String = "#FFD60A"
    var stripTilt = true

    // Side Accent
    var accentTextColor: String = "#FFFFFF"
    var accentColor: String = "#FF375F"
    var accentBackdrop = true

    // Outline
    var outlineTextColor: String = "#FFFFFF"
    var outlineColor: String = "#000000"
    /// Outline width as a fraction of the font size.
    var outlineWidth: Double = 0.14
}

nonisolated extension HookStyle {
    /// Clips saved before a field existed don't have it; they keep the default instead of losing the whole style.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HookStyle()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        enabled = try value(.enabled, d.enabled)
        duration = try value(.duration, d.duration)
        look = (try? c.decodeIfPresent(HookLook.self, forKey: .look)) ?? d.look
        fontName = try value(.fontName, d.fontName)
        size = try value(.size, d.size)
        uppercase = try value(.uppercase, d.uppercase)
        positionY = try value(.positionY, d.positionY)
        textColor = try value(.textColor, d.textColor)
        boxColor = try value(.boxColor, d.boxColor)
        cornerRadius = try value(.cornerRadius, d.cornerRadius)
        stripTextColor = try value(.stripTextColor, d.stripTextColor)
        stripColor = try value(.stripColor, d.stripColor)
        stripTilt = try value(.stripTilt, d.stripTilt)
        accentTextColor = try value(.accentTextColor, d.accentTextColor)
        accentColor = try value(.accentColor, d.accentColor)
        accentBackdrop = try value(.accentBackdrop, d.accentBackdrop)
        outlineTextColor = try value(.outlineTextColor, d.outlineTextColor)
        outlineColor = try value(.outlineColor, d.outlineColor)
        outlineWidth = try value(.outlineWidth, d.outlineWidth)
    }
}

nonisolated enum WatermarkPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing, center
    var id: String { rawValue }
}

nonisolated struct WatermarkSettings: Codable, Hashable, Sendable {
    var enabled = false
    var useImage = false
    var text = ""
    var imagePath = ""
    var position: WatermarkPosition = .topTrailing
    var opacity: Double = 0.7
    /// Width of an image watermark, or font size of a text one, as a fraction of frame width.
    var size: Double = 0.18

    static var current: WatermarkSettings {
        guard let data = UserDefaults.standard.data(forKey: AppSettings.Key.watermark),
              let value = try? JSONDecoder().decode(WatermarkSettings.self, from: data) else { return WatermarkSettings() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.Key.watermark)
        }
    }
}

// MARK: - Moments

nonisolated enum ClipCategory: String, Codable, CaseIterable, Sendable {
    case educational, inspirational, controversial, story, funny, relatable

    var label: String {
        switch self {
        case .educational: String(localized: "Educational")
        case .inspirational: String(localized: "Inspirational")
        case .controversial: String(localized: "Hot Take")
        case .story: String(localized: "Story")
        case .funny: String(localized: "Funny")
        case .relatable: String(localized: "Relatable")
        }
    }

    var symbol: String {
        switch self {
        case .educational: "lightbulb"
        case .inspirational: "sparkles"
        case .controversial: "flame"
        case .story: "book"
        case .funny: "face.smiling"
        case .relatable: "person.2"
        }
    }

    static func loose(_ raw: String) -> ClipCategory {
        let s = raw.lowercased()
        if s.contains("educ") || s.contains("learn") { return .educational }
        if s.contains("inspir") || s.contains("motiv") { return .inspirational }
        if s.contains("contro") || s.contains("hot") || s.contains("debat") { return .controversial }
        if s.contains("story") || s.contains("anec") { return .story }
        if s.contains("fun") || s.contains("entert") || s.contains("humor") { return .funny }
        if s.contains("relat") { return .relatable }
        return .story
    }
}

/// A moment proposed by a moment finder, before it becomes a saved clip.
nonisolated struct MomentCandidate: Sendable, Hashable {
    var start: Double
    var end: Double
    var title: String
    var hook: String
    var summary: String
    var category: ClipCategory
    /// 0…10
    var score: Double
}

// MARK: - Helpers

nonisolated func formatTimestamp(_ seconds: Double, alwaysHours: Bool = false) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 || alwaysHours { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

nonisolated func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s" }
    return String(format: "%d:%02d", s / 60, s % 60)
}

nonisolated extension StringProtocol {
    /// Whether the text finishes a sentence.
    var endsSentence: Bool { last.map { ".?!…".contains($0) } ?? false }
}

nonisolated extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
