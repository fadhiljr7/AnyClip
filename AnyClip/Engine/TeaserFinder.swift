//
//  TeaserFinder.swift
//  AnyClip
//
//  Suggests teaser (cold-open) moments for a clip. The model sees the clip as
//  short numbered phrases and answers with phrase numbers plus a quote; the
//  words and timings always come from the transcript, so a teaser can't contain
//  anything the speaker didn't say. Cut points are then moved to the quietest
//  spot next to the first and last word.
//

import Foundation
import AVFoundation
import FoundationModels

nonisolated struct TeaserRequest: Sendable {
    /// The clip's caption words, in source time.
    var words: [Word]
    var clipStart: Double
    var clipEnd: Double
    var title: String
    var hook: String
    /// Transcript language code, e.g. "id".
    var language: String
    /// Audio used to place the cuts between words.
    var media: URL
    /// False for subtitle files, whose word timings are spread evenly across each line.
    var preciseTiming: Bool = true
}

nonisolated struct TeaserResult: Sendable {
    var candidates: [TeaserCandidate]
    var source: String
    var notice: String?
}

@Generable
nonisolated struct GeneratedTeaser {
    @Guide(description: "Which pull this moment has.", .anyOf(["statement", "curiosity", "emotion"]))
    var angle: String
    @Guide(description: "Number of the first phrase used (the P number).")
    var first: Int
    @Guide(description: "Number of the last phrase used; the same as first for a single phrase.")
    var last: Int
    @Guide(description: "The speaker's exact words for the teaser, copied from the phrases without changes.")
    var quote: String
    @Guide(description: "One short sentence on why this moment makes people keep watching.")
    var reason: String
    @Guide(description: "True if the line only makes sense after hearing what came before it.")
    var needsContext: Bool
    @Guide(description: "True if it gives away the clip's final answer or punchline.")
    var spoilsEnding: Bool
    @Guide(description: "How strong a teaser this is, 0 to 10. Be strict.", .range(0...10))
    var score: Int
}

@Generable
nonisolated struct GeneratedTeasers {
    @Guide(description: "At most one moment per angle. Leave an angle out when nothing fits; an empty list is fine.")
    var teasers: [GeneratedTeaser]
}

nonisolated enum TeaserFinder {
    /// The first seconds of a clip are already its opening, so a teaser never comes from there.
    static let openingGuard = 5.0
    static let minClipDuration = 10.0
    static let targetRange = 1.5...4.0
    static let maxDuration = 6.0

    @concurrent
    static func find(_ r: TeaserRequest, provider: AIProvider, useAI: Bool = true) async throws -> TeaserResult {
        let words = r.words.filter { $0.end > r.clipStart && $0.start < r.clipEnd }
        guard r.clipEnd - r.clipStart >= minClipDuration else {
            return TeaserResult(candidates: [], source: "", notice: String(localized: "This clip is too short for a teaser."))
        }
        let phrases = TeaserText.phrases(words)
        let firstUsable = phrases.first { $0.start >= r.clipStart + openingGuard }?.number ?? Int.max
        guard firstUsable != Int.max else {
            return TeaserResult(candidates: [], source: "", notice: String(localized: "This clip has too little speech for a teaser."))
        }

        var notice: String?
        var picks: [GeneratedTeaser]?
        var appleError: String?
        var source = ""
        if useAI, provider != .apple {
            if provider.apiKey == nil {
                notice = String(localized: "\(provider.displayName) has no API key, so Apple Intelligence was used instead.")
            } else {
                do {
                    let reply = try await CloudAI.complete(provider: provider, system: instructions(r),
                                                           prompt: prompt(r, phrases: phrases, firstUsable: firstUsable, json: true),
                                                           maxTokens: 2048)
                    engineLog("teaser: \(provider.displayName) replied \(reply.prefix(600))")
                    guard LooseJSON.object(from: reply) != nil else {
                        throw CloudAIError(provider: provider, status: 0, message: String(localized: "Its answer couldn’t be read."))
                    }
                    picks = parse(reply)
                    source = "\(provider.displayName) (\(provider.model))"
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    engineLog("teaser: \(provider.displayName) failed: \(error)")
                    if !AppSettings.fallbackToApple {
                        throw MomentError.providerFailed(CloudAI.failureMessage(error, provider: provider))
                    }
                    notice = CloudAI.fallbackNotice(error, provider: provider)
                }
            }
        }
        if useAI, picks == nil, case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession(instructions: instructions(r))
                let response = try await session.respond(to: prompt(r, phrases: phrases, firstUsable: firstUsable, json: false),
                                                         generating: GeneratedTeasers.self,
                                                         options: GenerationOptions(temperature: 0.3))
                picks = response.content.teasers
                source = String(localized: "Apple Intelligence (on this Mac)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                engineLog("teaser: Apple Intelligence failed: \(error)")
                appleError = error.localizedDescription
            }
        }

        var candidates: [TeaserCandidate]
        if let picks {
            candidates = picks.compactMap { candidate(from: $0, words: words, phrases: phrases, firstUsable: firstUsable, request: r) }
        } else {
            candidates = heuristic(words: words, phrases: phrases, firstUsable: firstUsable, request: r)
            source = String(localized: "Built-in scoring (no AI available)")
            notice = notice ?? appleError.map {
                String(localized: "Apple Intelligence couldn’t read this clip (\($0)), so moments were picked from strong words in the transcript.")
            } ?? String(localized: "No AI was available, so moments were picked from strong words in the transcript.")
        }
        candidates = distinct(candidates)
        for i in candidates.indices {
            var c = candidates[i]
            var snapped = await AudioSnap.refine(media: r.media, start: c.start, end: c.end, words: words)
            // Under about a second and a half a cold open doesn't register; bring in the line that sets it up.
            let seconds = snapped.end - snapped.start
            if seconds < 1.3, let range = TeaserText.wordRange(start: c.start, end: c.end, in: words),
               let longer = withSetup(range, words: words, phrases: phrases, firstUsable: firstUsable,
                                      limit: seconds < 1.0 ? maxDuration : targetRange.upperBound + 0.5) {
                let kept = c.warnings.filter { [.needsContext, .spoilsEnding].contains($0) }
                c = make(angle: c.angle, range: longer, words: words, request: r, reason: c.reason, score: c.score)
                c.warnings += kept
                snapped = await AudioSnap.refine(media: r.media, start: c.start, end: c.end, words: words)
            }
            c.start = snapped.start
            c.end = snapped.end
            if c.duration < 1.0 { c.warnings.append(.short) }
            // The clip's last line is usually its payoff.
            if c.end > r.clipEnd - 1.5, !c.warnings.contains(.spoilsEnding) { c.warnings.append(.spoilsEnding) }
            candidates[i] = c
        }
        // Under a second, even with its setup line added, a teaser passes before anyone notices it ("We aren't.").
        candidates.removeAll { $0.warnings.contains(.short) }
        if candidates.isEmpty, notice == nil {
            notice = String(localized: "No moment in this clip stands out enough to work as a teaser.")
        }
        return TeaserResult(candidates: candidates, source: source, notice: notice)
    }

    // MARK: Prompt

    static func uiLanguageName() -> String {
        let code = Bundle.main.preferredLocalizations.first ?? "en"
        return Locale(identifier: "en").localizedString(forIdentifier: code) ?? "English"
    }

    static func instructions(_ r: TeaserRequest) -> String {
        """
        You are an editor of short vertical videos. You choose cold-open teasers: a 2–3 second moment from later \
        in a clip that plays first, before the clip starts, so viewers stay to hear the full story. \
        You only ever use the speaker's own words, exactly as transcribed.
        """
    }

    static func prompt(_ r: TeaserRequest, phrases: [TeaserPhrase], firstUsable: Int, json: Bool) -> String {
        let language = Locale(identifier: "en").localizedString(forIdentifier: r.language) ?? r.language
        let lines = phrases.map { p in
            let at = String(format: "%.1f", p.start - r.clipStart)
            let seconds = String(format: "%.1f", p.end - p.start)
            return "P\(p.number) [\(at)s, \(seconds)s, \(p.last - p.first + 1) words] \(p.text)"
        }.joined(separator: "\n")
        let shape = json ? """

        Reply with JSON only, in this shape:
        {"teasers":[{"angle":"statement","first":7,"last":7,"quote":"…","reason":"…","needs_context":false,"spoils_ending":false,"score":8}]}
        """ : ""
        return """
        Clip headline: \(r.title)
        On-screen hook: \(r.hook)
        The clip is in \(language). It is split into numbered phrases below. P1–P\(firstUsable - 1) are its opening \
        and must not be used.

        Choose up to 3 teaser moments, at most one per angle:
        - statement: a bold, direct or surprising claim.
        - curiosity: a line that makes viewers need to know what happened or why.
        - emotion: a strong feeling or reaction — fear, regret, pride, anger, laughter.
        Judge each moment on hook strength, curiosity, emotion, whether it makes sense on its own, how it connects to \
        the clip, and whether it fits in about 2–3 seconds. Don't simply take the loudest or most dramatic-sounding line.
        Rules:
        - Keep it short: usually 4–10 words, about 2–3 seconds, never under 1.5 or over 5 seconds. When a phrase is \
        longer, quote only its punchiest part. A two- or three-word reply ("You'd be wrong.") needs the line before it.
        - The quote must be a complete thought: a whole sentence or clause, never one that stops in the middle \
        ("…will either be").
        - "quote" is the speaker's exact words, copied in order from one phrase or consecutive phrases. Never change, \
        add, reorder or translate words.
        - It must stay true to what the speaker means. Never choose a line that becomes misleading out of context.
        - Create curiosity without giving away the clip's final answer or punchline.
        - Skip filler, greetings, sponsor lines and lines that hang on an earlier sentence ("that's why", "he said").
        - If nothing fits an angle, leave it out. Return fewer moments, or none, rather than a weak one.
        Write "reason" in \(uiLanguageName()): one short sentence on why it works as a teaser.\(shape)

        Phrases (P<number> [start in the clip, length, word count] text):
        \(lines)
        """
    }

    static func parse(_ reply: String) -> [GeneratedTeaser] {
        let root = LooseJSON.object(from: reply)
        let items: [[String: Any]]
        if let dict = root as? [String: Any] {
            items = (dict["teasers"] ?? dict["moments"] ?? dict.values.first(where: { $0 is [Any] })) as? [[String: Any]] ?? []
        } else {
            items = root as? [[String: Any]] ?? []
        }
        return items.compactMap { item in
            func int(_ k: String) -> Int? { LooseJSON.int(item[k], prefix: "P") }
            guard let first = int("first") ?? int("first_phrase") else { return nil }
            return GeneratedTeaser(angle: item["angle"] as? String ?? "", first: first, last: int("last") ?? int("last_phrase") ?? first,
                                   quote: item["quote"] as? String ?? "", reason: item["reason"] as? String ?? "",
                                   needsContext: item["needs_context"] as? Bool ?? false,
                                   spoilsEnding: item["spoils_ending"] as? Bool ?? false,
                                   score: int("score") ?? 5)
        }
    }

    // MARK: Turning picks into cut points

    static func candidate(from g: GeneratedTeaser, words: [Word], phrases: [TeaserPhrase], firstUsable: Int,
                          request r: TeaserRequest) -> TeaserCandidate? {
        guard let angle = TeaserAngle.loose(g.angle) else { return nil }
        // A pick inside the clip's opening would just repeat it.
        guard max(g.first, g.last) >= firstUsable else { return nil }
        let a = max(min(g.first, g.last), firstUsable), b = max(a, max(g.first, g.last))
        guard let pa = phrases.first(where: { $0.number == a }), let pb = phrases.first(where: { $0.number == min(b, a + 3) })
        else { return nil }
        var range = pa.first...pb.last
        // The quote may be part of the phrases; it also catches a model that drifts from the numbers.
        let window = max(0, pa.first - 2)...min(words.count - 1, pb.last + 2)
        if let quoted = TeaserText.align(quote: g.quote, in: words, range: window),
           words[quoted.lowerBound].start >= r.clipStart + openingGuard - 0.5 {
            range = quoted
        }
        range = fit(range, words: words, phrases: phrases)
        if words[range.upperBound].end - words[range.lowerBound].start > maxDuration {
            // Keep the closing sentences, where the punch usually is; chopping the end would cut mid-sentence.
            guard let ending = ending(of: range, words: words, phrases: phrases) else {
                engineLog("teaser: dropped \(angle.rawValue) pick, too long: \(g.quote)")
                return nil
            }
            range = ending
        }
        var c = make(angle: angle, range: range, words: words, request: r,
                     reason: g.reason.trimmingCharacters(in: .whitespacesAndNewlines), score: Double(g.score))
        // A piece that both starts and ends mid-sentence is a fragment, not a teaser.
        if c.warnings.contains(.startsMidSentence) && c.warnings.contains(.endsMidSentence) {
            engineLog("teaser: dropped \(angle.rawValue) fragment: \(c.text)")
            return nil
        }
        if g.needsContext { c.warnings.append(.needsContext) }
        if g.spoilsEnding { c.warnings.append(.spoilsEnding) }
        return c
    }

    /// Keeps a teaser near the target length: widens a fragment to its phrase, trims a long run to its strongest end.
    static func fit(_ range: ClosedRange<Int>, words: [Word], phrases: [TeaserPhrase]) -> ClosedRange<Int> {
        var lo = range.lowerBound, hi = range.upperBound
        func span() -> Double { words[hi].end - words[lo].start }
        if span() < targetRange.lowerBound, let phrase = phrases.first(where: { $0.first <= lo && $0.last >= lo }) {
            lo = min(lo, phrase.first)
            hi = max(hi, phrase.last)
        }
        return lo...hi
    }

    /// The shortest run of whole sentences (or phrases) at the end of `range` that fits a teaser.
    static func ending(of range: ClosedRange<Int>, words: [Word], phrases: [TeaserPhrase]) -> ClosedRange<Int>? {
        let hi = range.upperBound
        let sentenceStarts = range.filter { $0 == range.lowerBound || words[$0 - 1].text.endsSentence }
        let phraseStarts = phrases.map(\.first).filter { range.contains($0) }
        for starts in [sentenceStarts, phraseStarts] {
            // From the earliest start, so the longest ending that still fits wins.
            for start in starts.sorted() where start > range.lowerBound || starts.count == 1 {
                let span = words[hi].end - words[start].start
                if span <= maxDuration && span >= targetRange.lowerBound { return start...hi }
            }
        }
        return nil
    }

    /// Adds the phrase before a very short teaser when the two together still fit.
    static func withSetup(_ range: ClosedRange<Int>, words: [Word], phrases: [TeaserPhrase], firstUsable: Int,
                          limit: Double) -> ClosedRange<Int>? {
        guard let own = phrases.first(where: { $0.first <= range.lowerBound && $0.last >= range.lowerBound }),
              own.number - 1 >= firstUsable, let previous = phrases.first(where: { $0.number == own.number - 1 }) else { return nil }
        var from = previous.first
        if TeaserText.hasPunctuation(words) {
            // With punctuation, the setup must be a whole sentence, not the tail of one.
            guard range.lowerBound > 0, words[range.lowerBound - 1].text.endsSentence else { return nil }
            from = range.lowerBound - 1
            while from > 0, !words[from - 1].text.endsSentence { from -= 1 }
            guard let usable = phrases.first(where: { $0.number == firstUsable }), from >= usable.first else { return nil }
        }
        let longer = from...range.upperBound
        guard words[longer.upperBound].end - words[longer.lowerBound].start <= limit else { return nil }
        return longer
    }

    static func make(angle: TeaserAngle, range: ClosedRange<Int>, words: [Word], request r: TeaserRequest,
                     reason: String, score: Double) -> TeaserCandidate {
        let cut = TeaserText.cutPoints(words: words, range: range)
        var c = TeaserCandidate(angle: angle, start: cut.start, end: cut.end,
                                text: words[range].map(\.text).joined(separator: " "),
                                reason: reason, score: score.clamped(to: 0...10))
        c.warnings = sentenceWarnings(range: range, words: words)
        if c.duration > targetRange.upperBound + 0.5 { c.warnings.append(.long) }
        if !r.preciseTiming { c.warnings.append(.roughTiming) }
        return c
    }

    static func sentenceWarnings(range: ClosedRange<Int>, words: [Word]) -> [TeaserWarning] {
        guard TeaserText.hasPunctuation(words) else { return [] }
        var result: [TeaserWarning] = []
        let ends: (Word) -> Bool = { $0.text.endsSentence }
        let lo = range.lowerBound, hi = range.upperBound
        let first = words[lo].text.first
        let startsSentence = lo == 0 || ends(words[lo - 1]) || words[lo].start - words[lo - 1].end > 0.6
            || (first?.isUppercase ?? false) && !(words[lo - 1].text.last.map { ",;:".contains($0) } ?? false)
        if !startsSentence { result.append(.startsMidSentence) }
        let lastChar = words[hi].text.last
        let endsClause = ends(words[hi]) || (lastChar.map { ",;:".contains($0) } ?? false)
            || hi + 1 >= words.count || words[hi + 1].start - words[hi].end > 0.6
        if !endsClause { result.append(.endsMidSentence) }
        return result
    }

    /// Drops overlapping candidates, keeping the stronger one, and orders them by angle.
    static func distinct(_ candidates: [TeaserCandidate]) -> [TeaserCandidate] {
        var kept: [TeaserCandidate] = []
        for c in candidates.sorted(by: { $0.score > $1.score }) {
            let overlaps = kept.contains { min($0.end, c.end) - max($0.start, c.start) > 0.5 * min($0.duration, c.duration) }
            let sameAngle = kept.contains { $0.angle == c.angle }
            // Two lines saying the same thing aren't two choices, even when they're far apart.
            let sameMessage = kept.contains { TeaserText.repeats($0.text, c.text) }
            if !overlaps && !sameAngle && !sameMessage { kept.append(c) }
        }
        return kept.sorted { TeaserAngle.allCases.firstIndex(of: $0.angle)! < TeaserAngle.allCases.firstIndex(of: $1.angle)! }
    }

    // MARK: Built-in scoring

    private static let statementWords: Set<String> = Set("""
    juta miliar milyar triliun ribu persen rupiah rugi bangkrut hancur gagal sukses kaya miskin utang hutang \
    semua nggak gak enggak tidak pernah selalu satu-satunya terbesar terburuk terbaik paling wajib jangan harus \
    million billion thousand percent never always biggest worst best only must lost broke fired quit everything nothing
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let curiosityWords: Set<String> = Set("""
    ternyata rahasia kenapa gimana bagaimana apa tiba-tiba akhirnya justru padahal sebenarnya sebenernya nggak nyangka \
    siapa tahu tau ketahuan misteri aneh \
    secret why how what suddenly turns turned actually nobody expected realized surprise strange
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let emotionWords: Set<String> = Set("""
    takut nangis menangis sedih senang bahagia bangga marah kecewa malu sakit hati cinta benci nyesel menyesal kaget \
    stres depresi capek lelah putus asa ketawa lucu gila \
    afraid scared cried cry sad happy proud angry disappointed ashamed hurt love hate regret shocked tired crazy laughed
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    static func heuristic(words: [Word], phrases: [TeaserPhrase], firstUsable: Int, request r: TeaserRequest) -> [TeaserCandidate] {
        var picks: [TeaserCandidate] = []
        for angle in TeaserAngle.allCases {
            var best: (score: Double, phrase: TeaserPhrase)?
            for p in phrases where p.number >= firstUsable && p.end - p.start >= 1 && p.end - p.start <= maxDuration {
                let tokens = p.text.lowercased().split(whereSeparator: \.isWhitespace).map { TeaserText.token(String($0)) }
                let count: (Set<String>) -> Double = { set in Double(tokens.filter { set.contains($0) }.count) }
                let numbers = Double(tokens.filter { $0.first?.isNumber ?? false }.count)
                var score: Double = switch angle {
                case .statement: count(statementWords) * 1.4 + numbers * 1.6 + (p.text.hasSuffix("!") ? 1 : 0)
                case .curiosity: count(curiosityWords) * 1.5 + (p.text.contains("?") ? 1.5 : 0)
                case .emotion: count(emotionWords) * 1.8 + (p.text.hasSuffix("!") ? 0.8 : 0)
                }
                // Short, complete lines make better teasers.
                let seconds = p.end - p.start
                if targetRange.contains(seconds) { score += 0.6 }
                guard score >= 2.2 else { continue }
                if best == nil || score > best!.score { best = (score, p) }
            }
            guard let best else { continue }
            let reason: String = switch angle {
            case .statement: String(localized: "A direct claim with strong words or numbers.")
            case .curiosity: String(localized: "Raises a question viewers will want answered.")
            case .emotion: String(localized: "The speaker shows strong feeling here.")
            }
            picks.append(make(angle: angle, range: fit(best.phrase.first...best.phrase.last, words: words, phrases: phrases),
                              words: words, request: r, reason: reason, score: min(7, 3 + best.score)))
        }
        return picks
    }
}

// MARK: - Cutting between words

nonisolated enum AudioSnap {
    /// Moves each cut to the quietest moment just outside the word, so it never clips a syllable.
    /// Word timings from speech recognition are often 0.1–0.2 s off; the audio isn't.
    @concurrent
    static func refine(media: URL, start: Double, end: Double, words: [Word]) async -> (start: Double, end: Double) {
        guard let range = TeaserText.wordRange(start: start, end: end, in: words) else { return (start, end) }
        let firstIndex = range.lowerBound, lastIndex = range.upperBound
        let first = words[firstIndex], last = words[lastIndex]
        let prevEnd = firstIndex > 0 ? words[firstIndex - 1].end : first.start - 0.5
        let nextStart = lastIndex + 1 < words.count ? words[lastIndex + 1].start : last.end + 0.5

        // Search a little before the first word (but not into the previous one) and a little after the last.
        // Timings can overlap, so never let a window run backwards.
        func window(_ a: Double, _ b: Double) -> ClosedRange<Double> { min(a, b)...max(a, b) }
        let startWindow = window(max(prevEnd - 0.05, first.start - 0.3), first.start + 0.04)
        let endWindow = window(max(last.end - 0.06, last.start + 0.12), min(max(nextStart + 0.04, last.end), last.end + 0.3))
        guard endWindow.upperBound - startWindow.lowerBound < 12 else { return (start, end) }
        guard let levels = try? await rms(media: media, from: startWindow.lowerBound, to: endWindow.upperBound) else { return (start, end) }

        // Where the voice actually stops: some transcripts stretch a word's end to the next word's start, which would
        // leave a pause at the end of the teaser.
        let stop = voiceStops(levels.filter { $0.time >= last.start }, after: last.start + 0.1, until: endWindow.upperBound)
        let newStart = quietest(levels, in: startWindow, preferring: start) ?? start
        let newEnd = stop.map { $0 + 0.06 } ?? quietest(levels, in: endWindow, preferring: end).map { $0 + 0.01 } ?? end
        guard newEnd - newStart > 0.5 else { return (start, end) }
        return (newStart, newEnd)
    }

    /// Cut points for a whole clip: in the pause before its first word, and a breath after the voice stops on its
    /// last word — never into the next word. Transcripts often stretch a word's end up to where the next word
    /// starts, so cutting on the transcript alone leaves the start of the next sentence at the end of the clip.
    @concurrent
    static func clipBounds(media: URL, start: Double, end: Double, words: [Word]) async -> (start: Double, end: Double) {
        guard let range = TeaserText.wordRange(start: start, end: end, in: words) else { return (start, end) }
        let first = words[range.lowerBound], last = words[range.upperBound]
        let prevEnd = range.lowerBound > 0 ? words[range.lowerBound - 1].end : first.start - 0.5
        let nextStart = range.upperBound + 1 < words.count ? words[range.upperBound + 1].start : last.end + 0.6
        // Never past the point where the next word begins.
        let limit = max(nextStart - 0.04, last.start + 0.15)

        var newStart = start
        let startWindow = min(max(prevEnd - 0.05, first.start - 0.3), first.start)...(first.start + 0.04)
        if let levels = try? await rms(media: media, from: startWindow.lowerBound, to: startWindow.upperBound),
           let quiet = quietest(levels, in: startWindow, preferring: first.start - 0.08) {
            newStart = quiet
        }

        var newEnd = min(end, limit)
        // Look from the last word to the next one (at least a second, for a clip that ends the video).
        let lookUntil = max(nextStart, last.start + 1)
        if let levels = try? await rms(media: media, from: last.start, to: lookUntil + 0.05) {
            if let stop = voiceStops(levels, after: last.start + 0.1, until: lookUntil) {
                // A short tail so the last syllable fades out instead of being chopped.
                newEnd = min(stop + 0.18, limit)
            } else if let quiet = quietest(levels, in: max(last.start + 0.12, min(last.end, limit) - 0.3)...limit,
                                           preferring: min(last.end, limit)) {
                newEnd = min(quiet + 0.01, limit)
            }
        }
        guard newEnd - newStart > 1 else { return (start, min(end, limit)) }
        return (newStart, newEnd)
    }

    /// The moment nearest `target` that is close to the quietest level in the window.
    static func quietest(_ levels: [(time: Double, level: Float)], in window: ClosedRange<Double>, preferring target: Double) -> Double? {
        let frames = levels.filter { window.contains($0.time) }
        guard let floor = frames.map(\.level).min(), let peak = frames.map(\.level).max(), peak > 0 else { return nil }
        let threshold = floor + (peak - floor) * 0.12
        return frames.filter { $0.level <= threshold }.min { abs($0.time - target) < abs($1.time - target) }?.time
    }

    /// The first moment after `after` from which the audio stays quiet for 0.15 s: where the voice stops.
    static func voiceStops(_ levels: [(time: Double, level: Float)], after: Double, until: Double) -> Double? {
        let frames = levels.filter { $0.time <= until }
        guard let floor = frames.map(\.level).min(), let peak = frames.map(\.level).max(), peak > 0 else { return nil }
        let threshold = floor + (peak - floor) * 0.12
        let hold = 0.15
        for (i, f) in frames.enumerated() where f.time >= after {
            let ahead = frames[i...].prefix { $0.time <= f.time + hold }
            if ahead.count >= 10, ahead.allSatisfy({ $0.level <= threshold }) { return f.time }
        }
        return nil
    }

    /// Loudness every 10 ms between two source times.
    static func rms(media: URL, from: Double, to: Double) async throws -> [(time: Double, level: Float)] {
        let begin = max(0, from)
        let timescale = CMTimeScale(PCMAudio.sampleRate)
        let range = CMTimeRange(start: CMTime(seconds: begin, preferredTimescale: timescale),
                                end: CMTime(seconds: to, preferredTimescale: timescale))
        var samples: [Float] = []
        var firstTime: Double?
        try await PCMAudio.read(media: media, range: range) { chunk, start in
            if firstTime == nil { firstTime = start }
            samples += chunk
        }
        let origin = firstTime.flatMap { $0.isFinite ? $0 : nil } ?? begin
        let hop = Int(PCMAudio.sampleRate / 100)
        return stride(from: 0, to: max(0, samples.count - hop), by: hop).map { i in
            let slice = samples[i..<(i + hop)]
            let level = (slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(hop)).squareRoot()
            return (origin + Double(i + hop / 2) / PCMAudio.sampleRate, level)
        }
    }
}
