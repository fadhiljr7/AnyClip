//
//  MomentFinder.swift
//  AnyClip
//
//  Chooses the strongest self-contained moments in a transcript and writes a
//  headline, on-screen hook and teaser for each. The model sees a numbered
//  transcript and answers with line numbers, which small models get right far
//  more often than timestamps.
//

import Foundation
import FoundationModels
import Security
import NaturalLanguage

nonisolated struct MomentRequest: Sendable {
    var lines: [TranscriptLine]
    var count: Int
    var length: ClipLength
    var language: String
    var videoTitle: String
    var channel: String
    var topic: String
}

nonisolated struct MomentResult: Sendable {
    var moments: [MomentCandidate]
    /// Human-readable description of what produced the moments, shown in the UI.
    var source: String
    /// Set when the chosen provider failed and another one took over.
    var notice: String?
}

nonisolated enum MomentError: LocalizedError {
    case providerFailed(String)
    var errorDescription: String? {
        switch self { case .providerFailed(let m): m }
    }
}

nonisolated func engineLog(_ message: String) {
    #if DEBUG
    FileHandle.standardError.write(Data("[AnyClip AI] \(message)\n".utf8))
    #endif
}

@Generable
nonisolated struct GeneratedMoment {
    @Guide(description: "Number of the transcript line where the clip starts (the hook line, never filler).")
    var startLine: Int
    @Guide(description: "Number of the transcript line where the clip ends, right after the payoff.")
    var endLine: Int
    @Guide(description: "Scroll-stopping headline, at most 8 words, in the transcript's language.")
    var title: String
    @Guide(description: "Short on-screen hook shown in the first seconds, at most 12 words, in the transcript's language.")
    var hook: String
    @Guide(description: "One-sentence teaser for the post caption, in the transcript's language.")
    var summary: String
    @Guide(description: "Kind of moment.", .anyOf(["educational", "inspirational", "controversial", "story", "funny", "relatable"]))
    var category: String
    @Guide(description: "How likely this is to go viral, 0 to 10. Be strict: most moments are 4 to 7.", .range(0...10))
    var score: Int
}

@Generable
nonisolated struct GeneratedMoments {
    @Guide(description: "The best moments, strongest first.")
    var moments: [GeneratedMoment]
}

nonisolated enum AppEntitlements {
    /// Private Cloud Compute is a managed entitlement; without it FoundationModels traps instead of throwing.
    static let privateCloudCompute: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.private-cloud-compute" as CFString, nil) else { return false }
        return (value as? Bool) ?? true
    }()
}

nonisolated enum MomentFinder {
    @concurrent
    static func find(_ request: MomentRequest, provider: AIProvider,
                     onStatus: @Sendable @escaping (String, Double) -> Void) async throws -> MomentResult {
        guard !request.lines.isEmpty else { return MomentResult(moments: [], source: "") }
        var notice: String?
        if provider != .apple {
            if provider.apiKey == nil {
                notice = String(localized: "\(provider.displayName) has no API key, so Apple Intelligence was used instead.")
            } else {
                do {
                    let moments = try await cloud(request, provider: provider, onStatus: onStatus)
                    let fixed = try await enforceLanguage(moments, request: request, provider: provider)
                    engineLog("\(provider.displayName) returned \(fixed.count) moments")
                    return MomentResult(moments: finalize(fixed, request: request),
                                        source: "\(provider.displayName) (\(provider.model))")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    engineLog("\(provider.displayName) failed: \(error)")
                    if !AppSettings.fallbackToApple {
                        throw MomentError.providerFailed(CloudAI.failureMessage(error, provider: provider))
                    }
                    notice = CloudAI.fallbackNotice(error, provider: provider)
                    onStatus(String(localized: "\(provider.displayName) failed — switching to Apple Intelligence…"), 0)
                }
            }
        }
        do {
            if let (moments, label) = try await apple(request, onStatus: onStatus), !moments.isEmpty {
                let fixed = try await enforceLanguage(moments, request: request, provider: .apple)
                return MomentResult(moments: finalize(fixed, request: request), source: label, notice: notice)
            }
        } catch {
            engineLog("Apple Intelligence failed: \(error)")
        }
        onStatus(String(localized: "Scoring moments…"), 0.9)
        let moments = heuristic(request)
        return MomentResult(moments: finalize(moments, request: request),
                            source: String(localized: "Built-in scoring (no AI available)"),
                            notice: notice ?? String(localized: "Apple Intelligence isn’t available, so titles come from the speaker’s own words."))
    }

    // MARK: Language

    /// Detects the dominant language of a short text, or nil when unsure.
    static func detectedLanguage(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (lang, p) = recognizer.languageHypotheses(withMaximum: 1).first, p > 0.6 else { return nil }
        return lang.rawValue
    }

    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        let base = { (s: String) in Locale(identifier: s).language.languageCode?.identifier ?? s }
        let x = base(a), y = base(b)
        // Malay and Indonesian share most vocabulary; the recognizer mixes them up.
        let malayic: Set<String> = ["id", "ms"]
        return x == y || (malayic.contains(x) && malayic.contains(y))
    }

    /// Titles and hooks must be in the video's language. Models that don't support a language
    /// sometimes answer in English, so check and rewrite (or fall back to the speaker's words).
    static func enforceLanguage(_ moments: [MomentCandidate], request r: MomentRequest, provider: AIProvider) async throws -> [MomentCandidate] {
        var result = moments
        for i in result.indices {
            let m = result[i]
            let text = "\(m.title). \(m.hook)"
            guard let lang = detectedLanguage(text), !sameLanguage(lang, r.language) else { continue }
            engineLog("wrong language (\(lang)) for “\(m.title)” — rewriting in \(r.language)")
            if let rewritten = try? await rewrite(m, request: r, provider: provider),
               let lang2 = detectedLanguage("\(rewritten.title). \(rewritten.hook)"), sameLanguage(lang2, r.language) {
                result[i] = rewritten
            } else {
                result[i] = speakerWordsFallback(m, request: r)
            }
        }
        return result
    }

    private static func rewrite(_ m: MomentCandidate, request r: MomentRequest, provider: AIProvider) async throws -> MomentCandidate {
        let languageName = Locale(identifier: "en").localizedString(forIdentifier: r.language) ?? r.language
        let native = Locale(identifier: r.language).localizedString(forIdentifier: r.language) ?? languageName
        let excerpt = r.lines.filter { $0.end > m.start && $0.start < m.end }.map(\.text).joined(separator: " ")
        let prompt = """
        Translate this headline and hook into \(languageName) (\(native)). Keep them short and punchy, \
        written the way the speaker talks. Answer only in \(languageName).
        Headline: \(m.title)
        Hook: \(m.hook)
        Summary: \(m.summary)
        What the speaker says: \(excerpt.prefix(1200))
        Reply with JSON: {"title":"…","hook":"…","summary":"…"}
        """
        let reply: String
        if provider == .apple {
            let session = LanguageModelSession(instructions: "You translate short social media text into \(languageName). Never answer in English.")
            reply = try await session.respond(to: prompt).content
        } else {
            reply = try await CloudAI.complete(provider: provider, system: "Answer in \(languageName) only.", prompt: prompt, maxTokens: 2048)
        }
        guard let dict = LooseJSON.object(from: reply) as? [String: Any] else { throw CloudAIError(provider: provider, status: 0, message: "No JSON") }
        var out = m
        out.title = cleanTitle(dict["title"] as? String ?? m.title)
        out.hook = (dict["hook"] as? String ?? m.hook).trimmingCharacters(in: .whitespacesAndNewlines)
        out.summary = (dict["summary"] as? String ?? m.summary).trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    /// Uses the strongest line the speaker actually said, so it is always in the right language.
    static func speakerWordsFallback(_ m: MomentCandidate, request r: MomentRequest) -> MomentCandidate {
        let lines = r.lines.filter { $0.end > m.start && $0.start < m.end }
        let text = lines.map(\.text).joined(separator: " ")
        let words = text.split(separator: " ")
        var out = m
        let question = lines.first { $0.text.contains("?") }?.text
        out.hook = (question ?? words.prefix(12).joined(separator: " "))
            .split(separator: " ").prefix(14).joined(separator: " ")
        out.title = words.prefix(6).joined(separator: " ").capitalized(with: Locale(identifier: r.language))
        out.summary = String(text.prefix(110))
        return out
    }

    // MARK: Prompt

    static func instructions(_ r: MomentRequest) -> String {
        let languageName = Locale(identifier: "en").localizedString(forIdentifier: r.language) ?? r.language
        let native = Locale(identifier: r.language).localizedString(forIdentifier: r.language) ?? languageName
        return """
        You are an expert editor of short vertical videos for TikTok, Reels and Shorts. \
        You choose moments from long videos that work on their own and make people stop scrolling.
        LANGUAGE: the transcript is in \(languageName) (\(native)). Write every title, hook and summary in \(languageName), \
        in the same casual style the speakers use. Never translate them into English.
        """
    }

    static func rules(_ r: MomentRequest, count: Int) -> String {
        let range = r.length.range
        let focus = r.topic.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "\nPrefer moments about: \(r.topic)."
        return """
        Pick the \(count) best moments in the transcript below. Each moment must:
        - run about \(Int(range.lowerBound))–\(Int(range.upperBound)) seconds (aim for \(Int(r.length.target)));
        - make sense without the rest of the video: start where the idea starts, never on a dangling "that" or "he";
        - open with a strong line in the first 3 seconds: a bold claim, a question, a surprising fact, emotion or conflict;
        - end right after the payoff: the answer, the punchline or the conclusion;
        - not overlap another moment.
        Skip sponsor reads, ads, promo codes, "like and subscribe", intros, outros and small talk.\(focus)

        Titles are headlines, not summaries: curiosity gaps, counter-intuitive claims, sharp how-tos. \
        No emoji, hashtags, clip numbers or quotes copied word for word.
        Score honestly from 0–10 on how well the first 3 seconds hook, how complete the story is, \
        how much value it gives and how shareable it is.
        """
    }

    static func numbered(_ lines: [TranscriptLine]) -> String {
        lines.map { "L\($0.index) [\(formatTimestamp($0.start))] \($0.text)" }.joined(separator: "\n")
    }

    static func chunks(_ lines: [TranscriptLine], budget: Int) -> [[TranscriptLine]] {
        var result: [[TranscriptLine]] = []
        var current: [TranscriptLine] = []
        var size = 0
        for line in lines {
            let cost = line.text.count + 14
            if size + cost > budget, !current.isEmpty {
                result.append(current)
                // Keep a little overlap so moments spanning a boundary survive.
                current = Array(current.suffix(3))
                size = current.reduce(0) { $0 + $1.text.count + 14 }
            }
            current.append(line)
            size += cost
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func perChunkCount(total: Int, chunks: Int) -> Int {
        chunks <= 1 ? total : min(max(2, Int((Double(total) * 1.6 / Double(chunks)).rounded(.up))), total)
    }

    // MARK: Cloud

    static func cloud(_ r: MomentRequest, provider: AIProvider,
                      onStatus: @Sendable (String, Double) -> Void) async throws -> [MomentCandidate] {
        let parts = chunks(r.lines, budget: provider.transcriptBudget)
        let each = perChunkCount(total: r.count, chunks: parts.count)
        var all: [MomentCandidate] = []
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            onStatus(String(localized: "Asking \(provider.displayName) (\(provider.model))… (\(i + 1)/\(parts.count))"), Double(i) / Double(parts.count))
            let info = r.videoTitle.isEmpty ? "" : "Video: \"\(r.videoTitle)\"\(r.channel.isEmpty ? "" : " by \(r.channel)")\n\n"
            let prompt = """
            \(info)\(rules(r, count: each))

            Reply with JSON only, in this shape:
            {"clips":[{"start_line":12,"end_line":19,"title":"…","hook":"…","summary":"…","category":"educational|inspirational|controversial|story|funny|relatable","score":7}]}

            Transcript (each line: L<number> [m:ss] text):
            \(numbered(part))
            """
            let reply = try await CloudAI.complete(provider: provider, system: instructions(r), prompt: prompt)
            let parsed = parseCloud(reply, lines: r.lines)
            engineLog("\(provider.displayName) part \(i + 1): \(reply.count) chars, \(parsed.count) moments. Reply starts: \(reply.prefix(300))")
            if parsed.isEmpty {
                throw CloudAIError(provider: provider, status: 0,
                                   message: reply.isEmpty ? String(localized: "It sent an empty answer.")
                                                          : String(localized: "Its answer couldn’t be read as clips."))
            }
            all += parsed
        }
        return all
    }

    static func parseCloud(_ reply: String, lines: [TranscriptLine]) -> [MomentCandidate] {
        let root = LooseJSON.object(from: reply)
        let items: [[String: Any]]
        if let dict = root as? [String: Any] {
            items = (dict["clips"] ?? dict["moments"] ?? dict.values.first(where: { $0 is [Any] })) as? [[String: Any]] ?? []
        } else {
            items = root as? [[String: Any]] ?? []
        }
        return items.compactMap { item in
            func int(_ k: String) -> Int? { LooseJSON.int(item[k], prefix: "L") }
            guard let a = int("start_line") ?? int("startLine"), let b = int("end_line") ?? int("endLine") else { return nil }
            return candidate(startLine: a, endLine: b, lines: lines,
                             title: item["title"] as? String ?? "", hook: item["hook"] as? String ?? "",
                             summary: item["summary"] as? String ?? "", category: item["category"] as? String ?? "",
                             score: Double(int("score") ?? 5))
        }
    }

    static func candidate(startLine: Int, endLine: Int, lines: [TranscriptLine], title: String, hook: String,
                          summary: String, category: String, score: Double) -> MomentCandidate? {
        guard let first = lines.first?.index, let last = lines.last?.index else { return nil }
        let a = min(startLine, endLine).clamped(to: first...last)
        let b = max(startLine, endLine).clamped(to: first...last)
        guard let la = lines.first(where: { $0.index == a }), let lb = lines.first(where: { $0.index == b }) else { return nil }
        return MomentCandidate(start: la.start, end: lb.end, title: cleanTitle(title), hook: hook.trimmingCharacters(in: .whitespacesAndNewlines),
                               summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                               category: ClipCategory.loose(category), score: score.clamped(to: 0...10))
    }

    static func cleanTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'#*"))
        t = t.replacingOccurrences(of: "#\\w+", with: "", options: .regularExpression)
        // Some models answer in all lowercase; headlines read better capitalised.
        if t == t.lowercased() { t = t.capitalized(with: nil) }
        return String(t.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Apple Intelligence

    static func apple(_ r: MomentRequest, onStatus: @Sendable (String, Double) -> Void) async throws -> ([MomentCandidate], String)? {
        let usePCC = AppSettings.allowPrivateCloud && AppEntitlements.privateCloudCompute
        if usePCC, PrivateCloudComputeLanguageModel().isAvailable {
            let pcc = PrivateCloudComputeLanguageModel()
            let context = (try? await pcc.contextSize) ?? 4096
            let budget = max(6_000, min(200_000, Int(Double(context) * 2.4)))
            if let moments = try? await runApple(r, budget: budget, label: "Private Cloud Compute", onStatus: onStatus) {
                if !moments.isEmpty { return (moments, String(localized: "Apple Intelligence (Private Cloud Compute)")) }
            }
        }
        let local = SystemLanguageModel.default
        guard case .available = local.availability else { return nil }
        // Languages the model doesn't officially support (e.g. Indonesian) often still work;
        // try, and let built-in scoring take over if the model refuses.
        let budget = max(3_000, Int(Double(local.contextSize) * 1.7))
        let moments = try await runApple(r, budget: budget, label: nil, onStatus: onStatus)
        return (moments, String(localized: "Apple Intelligence (on this Mac)"))
    }

    private static func runApple(_ r: MomentRequest, budget: Int, label: String?,
                                 onStatus: @Sendable (String, Double) -> Void) async throws -> [MomentCandidate] {
        let parts = chunks(r.lines, budget: budget)
        let each = perChunkCount(total: r.count, chunks: parts.count)
        var all: [MomentCandidate] = []
        var lastError: Error?
        let pcc = label != nil ? PrivateCloudComputeLanguageModel() : nil
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            onStatus(String(localized: "Apple Intelligence is reading… (\(i + 1)/\(parts.count))"), Double(i) / Double(parts.count))
            let session: LanguageModelSession
            if let pcc {
                session = LanguageModelSession(model: pcc, instructions: instructions(r))
            } else {
                session = LanguageModelSession(instructions: instructions(r))
            }
            let prompt = """
            \(rules(r, count: each))
            Return at most \(each) moments. Use the L numbers below for startLine and endLine.

            Transcript:
            \(numbered(part))
            """
            do {
                let response = try await session.respond(to: prompt, generating: GeneratedMoments.self,
                                                         options: GenerationOptions(temperature: 0.4))
                for m in response.content.moments.prefix(each) {
                    if let c = candidate(startLine: m.startLine, endLine: m.endLine, lines: part, title: m.title, hook: m.hook,
                                         summary: m.summary, category: m.category, score: Double(m.score)) {
                        all.append(c)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A refusal or guardrail hit on one part shouldn't sink the whole video.
                lastError = error
            }
        }
        if all.isEmpty, let lastError { throw lastError }
        return all
    }

    // MARK: Built-in scoring

    static let hookWords: Set<String> = [
        // English
        "secret", "never", "always", "truth", "mistake", "why", "how", "money", "million", "crazy", "shocking",
        "actually", "wrong", "biggest", "worst", "best", "nobody", "everyone", "stop", "problem", "love", "hate",
        "afraid", "fear", "lesson", "learned", "realized", "story", "first", "last",
        // Indonesian
        "rahasia", "jangan", "selalu", "kenapa", "gimana", "bagaimana", "uang", "juta", "miliar", "gila", "salah",
        "terbesar", "terburuk", "terbaik", "nggak", "gak", "takut", "pelajaran", "sadar", "cerita", "pertama", "masalah",
    ]

    static func heuristic(_ r: MomentRequest) -> [MomentCandidate] {
        let lines = r.lines
        guard !lines.isEmpty else { return [] }
        var windows: [(Int, Int, Double)] = []
        for i in lines.indices {
            var j = i
            while j + 1 < lines.count, lines[j].end - lines[i].start < r.length.target { j += 1 }
            let span = lines[j].end - lines[i].start
            guard r.length.range.contains(span) || (j == lines.count - 1 && span >= r.length.range.lowerBound * 0.6) else { continue }
            let text = lines[i...j].map(\.text).joined(separator: " ")
            let tokens = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let density = Double(tokens.count) / max(span, 1)
            var score = 4.0
            score += min(2.0, Double(text.filter { $0 == "?" }.count) * 0.5)
            score += min(1.0, Double(text.filter { $0 == "!" }.count) * 0.35)
            score += min(1.5, Double(tokens.filter { hookWords.contains($0) }.count) * 0.25)
            score += min(1.0, Double(tokens.filter { $0.first?.isNumber ?? false }.count) * 0.2)
            score += (density > 2.2 && density < 4.2) ? 0.8 : 0
            let firstHook = lines[i].text.contains("?") || lines[i].text.lowercased().split(separator: " ").contains { hookWords.contains(String($0)) }
            if firstHook { score += 1 }
            if i > 0, !lines[i - 1].text.isEmpty, !lines[i - 1].text.endsSentence { score -= 1 }
            windows.append((i, j, min(score, 9.5)))
        }
        windows.sort { $0.2 > $1.2 }
        var chosen: [(Int, Int, Double)] = []
        for w in windows where chosen.count < r.count {
            if chosen.allSatisfy({ w.1 < $0.0 || w.0 > $0.1 }) { chosen.append(w) }
        }
        return chosen.map { (i, j, score) in
            let text = lines[i...j].map(\.text).joined(separator: " ")
            let sentences = text.split(whereSeparator: { ".?!".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            let hookSentence = sentences.first(where: { text.contains($0 + "?") }) ?? sentences.first ?? text
            let titleWords = (sentences.first ?? text).split(separator: " ").prefix(7).joined(separator: " ")
            return MomentCandidate(start: lines[i].start, end: lines[j].end,
                                   title: titleWords.capitalized(with: Locale(identifier: r.language)),
                                   hook: hookSentence.split(separator: " ").prefix(12).joined(separator: " "),
                                   summary: String(text.prefix(110)),
                                   category: text.contains("?") ? .educational : .story, score: score)
        }
    }

    // MARK: Clean-up

    /// Whether a line finishes a sentence. Lines are also split after a long stretch without punctuation.
    static func endsSentence(_ line: TranscriptLine) -> Bool {
        line.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]} ").union(.whitespacesAndNewlines)).endsSentence
    }

    /// The closest line to `b` that ends a sentence while the clip keeps its length: first finishing the
    /// sentence it's in, otherwise stopping after the previous one. `b` itself when neither fits.
    static func sentenceEnd(near b: Int, from a: Int, lines: [TranscriptLine], range: ClosedRange<Double>) -> Int {
        guard !endsSentence(lines[b]) else { return b }
        var forward = b
        while forward + 1 < lines.count, lines[forward + 1].end - lines[a].start <= range.upperBound {
            forward += 1
            if endsSentence(lines[forward]) { return forward }
        }
        var back = b
        while back > a, lines[back - 1].end - lines[a].start >= range.lowerBound {
            back -= 1
            if endsSentence(lines[back]) { return back }
        }
        return b
    }

    /// Fits each moment to the requested length on line boundaries, removes overlaps and ranks.
    static func finalize(_ moments: [MomentCandidate], request r: MomentRequest) -> [MomentCandidate] {
        let lines = r.lines
        let range = r.length.range
        var fitted: [MomentCandidate] = []
        for var m in moments {
            guard var a = lines.firstIndex(where: { $0.end > m.start + 0.01 }),
                  var b = lines.lastIndex(where: { $0.start < m.end - 0.01 }), a <= b else { continue }
            while lines[b].end - lines[a].start < range.lowerBound {
                if b + 1 < lines.count { b += 1 } else if a > 0 { a -= 1 } else { break }
            }
            while lines[b].end - lines[a].start > range.upperBound, b > a {
                b -= 1
            }
            b = sentenceEnd(near: b, from: a, lines: lines, range: range)
            m.start = max(0, lines[a].start - 0.12)
            // Transcripts often stretch the last word up to the next one, so padding past the next line's start
            // would leave its first words at the end of the clip. Studio then trims to where the voice stops.
            let nextStart = b + 1 < lines.count ? lines[b + 1].start - 0.03 : .infinity
            m.end = max(lines[b].end, min(lines[b].end + 0.35, nextStart))
            if m.title.isEmpty { m.title = String(lines[a].text.split(separator: " ").prefix(7).joined(separator: " ")) }
            if m.hook.isEmpty { m.hook = m.title }
            fitted.append(m)
        }
        fitted.sort { $0.score > $1.score }
        var result: [MomentCandidate] = []
        for m in fitted where result.count < r.count {
            let overlaps = result.contains { other in
                let overlap = min(m.end, other.end) - max(m.start, other.start)
                return overlap > 0.3 * min(m.end - m.start, other.end - other.start)
            }
            if !overlaps { result.append(m) }
        }
        if result.count < r.count {
            // Top up with built-in scoring so people get the number of clips they asked for.
            for extra in heuristic(r) where result.count < r.count {
                let overlaps = result.contains { min(extra.end, $0.end) - max(extra.start, $0.start) > 0 }
                if !overlaps { var e = extra; e.score = min(e.score, 6); result.append(e) }
            }
        }
        return result.sorted { $0.score > $1.score }
    }
}
