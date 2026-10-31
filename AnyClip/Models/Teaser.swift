//
//  Teaser.swift
//  AnyClip
//
//  A teaser (cold open) replays a short, striking moment from later in a clip
//  before the clip starts. The moment always comes from the clip's own footage:
//  its words are the transcript's and its cut points come from word timings.
//

import Foundation

/// The kind of pull a teaser has. Candidates are suggested one per angle.
nonisolated enum TeaserAngle: String, Codable, CaseIterable, Identifiable, Sendable {
    case statement, curiosity, emotion

    var id: String { rawValue }

    var title: String {
        switch self {
        case .statement: String(localized: "Strong Statement")
        case .curiosity: String(localized: "Curiosity")
        case .emotion: String(localized: "Emotional Moment")
        }
    }

    var symbol: String {
        switch self {
        case .statement: "exclamationmark.bubble"
        case .curiosity: "questionmark.bubble"
        case .emotion: "heart.text.square"
        }
    }

    static func loose(_ raw: String) -> TeaserAngle? {
        let s = raw.lowercased()
        if s.contains("state") || s.contains("bold") || s.contains("claim") { return .statement }
        if s.contains("curio") || s.contains("myst") || s.contains("question") { return .curiosity }
        if s.contains("emot") || s.contains("feel") || s.contains("react") { return .emotion }
        return nil
    }
}

/// Things worth checking before using a candidate.
nonisolated enum TeaserWarning: String, Codable, Hashable, Sendable {
    case startsMidSentence, endsMidSentence, needsContext, spoilsEnding, long, short, roughTiming

    var message: String {
        switch self {
        case .startsMidSentence: String(localized: "Starts in the middle of a sentence.")
        case .endsMidSentence: String(localized: "Ends before the sentence is finished.")
        case .needsContext: String(localized: "May need the earlier context to make sense.")
        case .spoilsEnding: String(localized: "May give away the clip’s ending.")
        case .long: String(localized: "Longer than a typical teaser.")
        case .short: String(localized: "Very short — it may pass before viewers notice it.")
        case .roughTiming: String(localized: "Word timings here are approximate — check the cut in the preview.")
        }
    }
}

nonisolated struct TeaserCandidate: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var angle: TeaserAngle
    /// Cut points in source time, already padded to fall between words.
    var start: Double
    var end: Double
    /// The speaker's words in this span, from the transcript.
    var text: String
    /// Why it was picked, in the app's language.
    var reason: String
    var warnings: [TeaserWarning] = []
    /// 0…10, used to order candidates.
    var score: Double = 5

    var duration: Double { end - start }
}

/// Teaser suggestions for a clip and the one the user chose.
nonisolated struct TeaserPlan: Codable, Hashable, Sendable {
    var candidates: [TeaserCandidate] = []
    var selectedID: UUID?
    /// The chosen teaser's cut points, which the user can move word by word.
    var start: Double = 0
    var end: Double = 0
    /// What produced the candidates, e.g. "Groq (qwen/qwen3.8-27b)".
    var source: String = ""
    /// Explains a fallback or why there are no candidates.
    var notice: String?
    /// The clip's trim when the candidates were suggested, to notice when it has changed since.
    var analyzed: ClipSegment?

    /// True when the clip has been trimmed noticeably since the candidates were suggested.
    func isStale(start: Double, end: Double) -> Bool {
        guard let analyzed, !candidates.isEmpty else { return false }
        return abs(analyzed.start - start) > 1 || abs(analyzed.end - end) > 1
    }

    var selected: TeaserCandidate? { candidates.first { $0.id == selectedID } }

    mutating func select(_ candidate: TeaserCandidate) {
        selectedID = candidate.id
        start = candidate.start
        end = candidate.end
    }
}

/// A stretch of source video placed on the output timeline.
nonisolated struct ClipSegment: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
}

/// Maps between the finished video's time and source time: an optional teaser, then the clip.
nonisolated struct OutputTimeline: Hashable, Sendable {
    var teaser: ClipSegment?
    var main: ClipSegment

    var teaserDuration: Double { teaser?.duration ?? 0 }
    var duration: Double { teaserDuration + main.duration }

    /// Each piece with its offset in the output.
    var pieces: [(segment: ClipSegment, offset: Double)] {
        (teaser.map { [($0, 0.0)] } ?? []) + [(main, teaserDuration)]
    }

    /// Output time of a source time inside the main clip.
    func output(forSource t: Double) -> Double { teaserDuration + t - main.start }

    /// Source time shown at an output time.
    func source(forOutput t: Double) -> Double {
        if let teaser, t < teaser.duration { return teaser.start + t }
        return main.start + t - teaserDuration
    }

    func isTeaser(output t: Double) -> Bool { teaser != nil && t < teaserDuration }
}

// MARK: - Phrases

/// Short, numbered pieces of a clip's transcript that the AI chooses from.
nonisolated struct TeaserPhrase: Hashable, Sendable {
    var number: Int
    /// Range into the clip's words.
    var first: Int
    var last: Int
    var start: Double
    var end: Double
    var text: String
}

nonisolated enum TeaserText {
    /// Splits words at sentence ends, commas in long runs and pauses, so each phrase is a few seconds at most.
    static func phrases(_ words: [Word]) -> [TeaserPhrase] {
        var result: [TeaserPhrase] = []
        var first = 0
        func flush(_ last: Int) {
            guard last >= first else { return }
            let slice = words[first...last]
            result.append(TeaserPhrase(number: result.count + 1, first: first, last: last,
                                       start: slice.first!.start, end: slice.last!.end,
                                       text: slice.map(\.text).joined(separator: " ")))
            first = last + 1
        }
        for i in words.indices {
            let w = words[i]
            let count = i - first + 1
            let span = w.end - words[first].start
            let next = i + 1 < words.count ? words[i + 1] : nil
            let pause = next.map { $0.start - w.end } ?? 0
            let mark = w.text.last
            let sentenceEnd = mark.map { ".?!…".contains($0) } ?? false
            let comma = mark.map { ",;:".contains($0) } ?? false
            if next == nil || sentenceEnd || pause > 0.45 || (comma && count >= 5) || count >= 14 || span >= 4.5 {
                flush(i)
            }
        }
        return result
    }

    /// Contractions that carry no meaning of their own once the apostrophe is gone.
    private static let contractions: Set<String> = Set("""
    youd youre youll youve ive its dont cant thats theyre isnt arent wasnt werent aint didnt doesnt wont hes shes \
    weve theyve lets whats theres
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// The words of a line that carry its meaning: no stopwords, and Indonesian suffixes dropped ("hidupnya" → "hidup").
    static func contentWords(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isWhitespace)
            .map { BRollPlanner.clean(String($0)).lowercased() }
            .filter { $0.count >= 3 && !BRollPlanner.stopwords.contains($0) && !contractions.contains($0) }
            .map { BRollPlanner.stem($0) })
    }

    /// True when two lines say largely the same thing: most meaning words of the shorter one appear in the other.
    /// Used to keep a hook from repeating its teaser and to keep teaser candidates distinct.
    static func repeats(_ a: String, _ b: String) -> Bool {
        let x = contentWords(a), y = contentWords(b)
        let smaller = min(x.count, y.count)
        guard smaller > 0 else { return false }
        let shared = x.intersection(y).count
        return Double(shared) / Double(smaller) >= 0.6 && (shared >= 2 || smaller == 1)
    }

    /// Share of `reference`'s meaning words that also appear in `text`, 0…1.
    static func overlap(_ text: String, with reference: String) -> Double {
        let ref = contentWords(reference)
        guard !ref.isEmpty else { return 0 }
        return Double(contentWords(text).intersection(ref).count) / Double(ref.count)
    }

    /// Lowercased letters and digits only, for comparing a quote with the transcript.
    static func token(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Finds the run of words that best matches `quote` inside `range`, or nil when it doesn't match well.
    static func align(quote: String, in words: [Word], range: ClosedRange<Int>) -> ClosedRange<Int>? {
        let wanted = quote.split(whereSeparator: \.isWhitespace).map { token(String($0)) }.filter { !$0.isEmpty }
        guard !wanted.isEmpty, range.lowerBound >= 0, range.upperBound < words.count else { return nil }
        let have = words[range].map { token($0.text) }
        let n = wanted.count
        guard have.count >= 1 else { return nil }
        var best: (score: Int, from: Int)?
        for from in 0..<max(1, have.count - n + 1) {
            var score = 0
            for k in 0..<n where from + k < have.count && have[from + k] == wanted[k] { score += 1 }
            if best == nil || score > best!.score { best = (score, from) }
        }
        guard let best, Double(best.score) >= Double(n) * 0.6 else { return nil }
        let lo = range.lowerBound + best.from
        let hi = min(range.upperBound, lo + n - 1)
        return lo...hi
    }

    /// True when most words carry punctuation information, so sentence warnings mean something.
    static func hasPunctuation(_ words: [Word]) -> Bool {
        guard words.count >= 12 else { return false }
        let marked = words.filter { $0.text.last.map { ".?!…,".contains($0) } ?? false }.count
        return Double(marked) / Double(words.count) > 0.04
    }

    /// Indices of the words inside a cut. Word starts decide: they're reliable in every transcript, while ends
    /// can stretch over a pause (YouTube) and cuts sit a few milliseconds outside the words.
    static func wordRange(start: Double, end: Double, in words: [Word]) -> ClosedRange<Int>? {
        let slack = 0.08
        guard let lo = words.firstIndex(where: { $0.start >= start - slack }),
              let hi = words.lastIndex(where: { $0.start < end - slack }), lo <= hi else { return nil }
        return lo...hi
    }

    /// Cut points just outside the first and last word, without reaching into neighbouring words.
    static func cutPoints(words: [Word], range: ClosedRange<Int>) -> (start: Double, end: Double) {
        let a = words[range.lowerBound], b = words[range.upperBound]
        var start = a.start - 0.08
        var end = b.end + 0.15
        if range.lowerBound > 0 { start = max(start, min(words[range.lowerBound - 1].end + 0.02, a.start)) }
        if range.upperBound + 1 < words.count { end = min(end, max(words[range.upperBound + 1].start - 0.02, b.end)) }
        return (max(0, start), end)
    }
}
