//
//  HookWriter.swift
//  AnyClip
//
//  Suggests new on-screen hooks for a clip. Hooks are first written by the
//  moment finder; this writes them again on request, and when a teaser opens
//  the clip it asks for hooks that add to the teaser instead of repeating it.
//  Every suggestion is checked before it's offered: short, in the clip's
//  language, no numbers the speaker never said, and not a rewording of the
//  teaser.
//

import Foundation
import FoundationModels

nonisolated struct HookRequest: Sendable {
    /// What the speaker says in the clip.
    var transcript: String
    var title: String
    var currentHook: String
    /// What the teaser says, when one opens the clip.
    var teaser: String?
    /// Transcript language code, e.g. "id".
    var language: String
}

nonisolated struct HookResult: Sendable {
    var hooks: [String]
    var source: String
}

nonisolated enum HookError: LocalizedError {
    case noAI
    case nothingUsable
    case declined

    var errorDescription: String? {
        switch self {
        case .noAI: String(localized: "Writing hooks needs Apple Intelligence or an AI provider in Settings › AI.")
        case .nothingUsable: String(localized: "None of the suggested hooks fit this clip. Try again.")
        case .declined: String(localized: "Apple Intelligence declined to write hooks for this clip. Try again, or choose another AI provider in Settings › AI.")
        }
    }
}

@Generable
nonisolated struct GeneratedHooks {
    @Guide(description: "Three different on-screen hooks, each at most 12 words, in the transcript's language.", .count(3))
    var hooks: [String]
}

nonisolated enum HookWriter {
    @concurrent
    static func suggest(_ r: HookRequest, provider: AIProvider) async throws -> HookResult {
        if provider != .apple, provider.apiKey != nil {
            do {
                let reply = try await CloudAI.complete(provider: provider, system: MomentFinder.instructions(r.momentRequest),
                                                       prompt: prompt(r, json: true), maxTokens: 1024)
                engineLog("hooks: \(provider.displayName) replied \(reply.prefix(400))")
                let hooks = HookText.usable(parse(reply), request: r)
                guard !hooks.isEmpty else { throw HookError.nothingUsable }
                return HookResult(hooks: hooks, source: "\(provider.displayName) (\(provider.model))")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                engineLog("hooks: \(provider.displayName) failed: \(error)")
                if !AppSettings.fallbackToApple { throw error }
            }
        }
        guard case .available = SystemLanguageModel.default.availability else { throw HookError.noAI }
        let session = LanguageModelSession(instructions: MomentFinder.instructions(r.momentRequest))
        let response: LanguageModelSession.Response<GeneratedHooks>
        do {
            response = try await session.respond(to: prompt(r, json: false), generating: GeneratedHooks.self,
                                                 options: GenerationOptions(temperature: 0.7))
        } catch LanguageModelError.guardrailViolation {
            // Its safety filter sometimes trips on ordinary talks; say so plainly instead of showing the raw error.
            throw HookError.declined
        }
        let hooks = HookText.usable(response.content.hooks, request: r)
        guard !hooks.isEmpty else { throw HookError.nothingUsable }
        return HookResult(hooks: hooks, source: String(localized: "Apple Intelligence (on this Mac)"))
    }

    static func prompt(_ r: HookRequest, json: Bool) -> String {
        let language = Locale(identifier: "en").localizedString(forIdentifier: r.language) ?? r.language
        var teaserPart = ""
        if let teaser = r.teaser {
            teaserPart = """

            The video opens with a teaser: the speaker saying "\(teaser)". The hook is on screen during the teaser \
            and the first seconds of the clip, so the two are seen together.
            Each hook must add to the teaser, not repeat it: give the context the teaser leaves out, ask the \
            question it raises, or point to a related angle from the clip. Don't paraphrase the teaser and don't \
            reuse its key words.
            """
        }
        let shape = json ? "\nReply with JSON only: {\"hooks\":[\"…\",\"…\",\"…\"]}" : ""
        return """
        Clip headline (written by an editor, for context only — take facts only from the transcript): \(r.title)
        Current hook: \(r.currentHook)\(teaserPart)

        Write 3 different on-screen hooks for this clip. Each is at most 12 words, in \(language), written the way \
        the speaker talks, and makes people stay to watch.
        Every hook must be true to what the speaker says in the clip. Never add numbers, names or claims that \
        aren't in the transcript. No emoji, hashtags or quotation marks.\(shape)

        What the speaker says in the clip:
        \(r.transcript.prefix(6000))
        """
    }

    static func parse(_ reply: String) -> [String] {
        let root = LooseJSON.object(from: reply)
        if let dict = root as? [String: Any], let hooks = (dict["hooks"] ?? dict.values.first { $0 is [Any] }) as? [Any] {
            return hooks.compactMap { $0 as? String }
        }
        return (root as? [Any])?.compactMap { $0 as? String } ?? []
    }
}

nonisolated extension HookRequest {
    /// Reuses the moment finder's voice and language rules.
    var momentRequest: MomentRequest {
        MomentRequest(lines: [], count: 1, length: .auto, language: language, videoTitle: title, channel: "", topic: "")
    }
}

nonisolated enum HookText {
    static let maxWords = 16

    /// Trims the decoration models add: quotes, list markers, trailing spaces.
    static func clean(_ hook: String) -> String {
        var s = hook.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^(\d+[.)]|[-•*])\s*"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’ "))
        return s
    }

    /// Number words in English and Indonesian, so "ten moves" is checked like "10 moves". "One" and "satu" are left out:
    /// they're mostly ordinary words ("no one", "satu hal").
    private static let numberWords: Set<String> = Set("""
    two three four five six seven eight nine ten eleven twelve twenty thirty forty fifty hundred thousand million \
    billion trillion twice dozen \
    dua tiga empat lima enam tujuh delapan sembilan sepuluh sebelas belas puluh ratus seratus ribu seribu juta \
    sejuta miliar milyar triliun
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    /// Numbers a line states: runs of digits (thousands separators removed, "5.000" → "5000") and number words.
    static func numbers(_ text: String) -> Set<String> {
        let joined = text.replacingOccurrences(of: #"(?<=\d)[.,](?=\d{3}\b)"#, with: "", options: .regularExpression)
        let regex = /\d+/
        let digits = joined.matches(of: regex).map { String($0.output) }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter(numberWords.contains)
        return Set(digits + words)
    }

    /// Hooks worth offering: short, in the clip's language, with no numbers the speaker never said,
    /// not a rewording of the teaser or the current hook, and not repeating each other.
    static func usable(_ hooks: [String], request r: HookRequest) -> [String] {
        let spoken = numbers(r.transcript)
        var kept: [String] = []
        for raw in hooks {
            let hook = clean(raw)
            let words = hook.split(whereSeparator: \.isWhitespace).count
            guard words >= 2, words <= maxWords else { continue }
            guard numbers(hook).isSubset(of: spoken) else { continue }
            // Stricter than the warning shown for the user's own hook: a suggestion may not reuse half the teaser's key words.
            if let teaser = r.teaser, TeaserText.repeats(hook, teaser) || TeaserText.overlap(hook, with: teaser) >= 0.5 { continue }
            if hook.caseInsensitiveCompare(r.currentHook) == .orderedSame { continue }
            if let detected = MomentFinder.detectedLanguage(hook), !MomentFinder.sameLanguage(detected, r.language) { continue }
            if kept.contains(where: { TeaserText.repeats($0, hook) }) { continue }
            kept.append(hook)
        }
        return kept
    }
}
