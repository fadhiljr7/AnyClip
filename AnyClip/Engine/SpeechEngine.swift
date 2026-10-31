//
//  SpeechEngine.swift
//  AnyClip
//
//  On-device transcription with word timings using SpeechAnalyzer.
//

import Foundation
import AVFoundation
import Speech
import NaturalLanguage

nonisolated enum SpeechEngineError: LocalizedError {
    case unsupportedLanguage(String)
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let code):
            let name = Locale.current.localizedString(forIdentifier: code) ?? code
            return String(localized: "On-device transcription doesn’t support \(name) yet. Attach a subtitle file or pick another language.")
        case .noSpeech:
            return String(localized: "No speech was found in this video.")
        }
    }
}

nonisolated enum SpeechEngine {
    enum Phase: Sendable { case preparingModel(Double), transcribing(Double) }

    /// Best guess at the spoken language when the user picks "Automatic".
    static func guessLanguage(hint: String?, sampleText: String) -> String {
        if let hint, !hint.isEmpty { return hint }
        if sampleText.count > 12, let lang = detectLanguage(in: sampleText) { return lang }
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    /// Detects the language sentence by sentence and adds up the scores, weighted by length.
    /// Scoring a title and description as one run of text can go badly wrong (an English TEDx
    /// description scored 70% Vietnamese), while each sentence on its own is reliable.
    /// `candidates` limits the answer to those language codes.
    static func detectLanguage(in text: String, among candidates: [String]? = nil) -> String? {
        let recognizer = NLLanguageRecognizer()
        if let candidates {
            recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
        }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var scores: [String: Double] = [:]
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.count > 3 else { return true }
            recognizer.reset()
            recognizer.processString(sentence)
            for (language, p) in recognizer.languageHypotheses(withMaximum: 3) {
                scores[language.rawValue, default: 0] += p * Double(sentence.count)
            }
            return true
        }
        return scores.max { $0.value < $1.value }?.key
    }

    @concurrent
    static func transcribe(media: URL, language: String, duration: Double,
                           onPhase: @Sendable @escaping (Phase) -> Void) async throws -> Transcript {
        let requested = Locale(identifier: language)
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                           attributeOptions: [.audioTimeRange])
            try await installAssets(for: module, onPhase: onPhase)
            let words = try await analyze(media: media, module: module, duration: duration, onPhase: onPhase) {
                try await collect(module.results.map { ($0.text, $0.range) }, duration: duration, onPhase: onPhase)
            }
            return Transcript(language: language, words: words)
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            let module = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                              reportingOptions: [], attributeOptions: [.audioTimeRange])
            try await installAssets(for: module, onPhase: onPhase)
            let words = try await analyze(media: media, module: module, duration: duration, onPhase: onPhase) {
                try await collect(module.results.map { ($0.text, $0.range) }, duration: duration, onPhase: onPhase)
            }
            return Transcript(language: language, words: words)
        }
        throw SpeechEngineError.unsupportedLanguage(language)
    }

    private static func installAssets(for module: any SpeechModule, onPhase: @Sendable @escaping (Phase) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let progress = request.progress
        let watcher = Task {
            while !Task.isCancelled {
                onPhase(.preparingModel(progress.fractionCompleted))
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
    }

    private static func analyze(media: URL, module: any SpeechModule, duration: Double,
                                onPhase: @Sendable @escaping (Phase) -> Void,
                                collector: @Sendable @escaping () async throws -> [Word]) async throws -> [Word] {
        onPhase(.transcribing(0))
        let analyzer = SpeechAnalyzer(modules: [module])
        let results = Task { try await collector() }
        do {
            let asset = AVURLAsset(url: media)
            let provider = try await AssetInputSequenceProvider.provider(from: asset, compatibleWith: [module])
            if let last = try await analyzer.analyzeSequence(provider.analyzerInputs) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            results.cancel()
            throw error
        }
        let words = try await withTaskCancellationHandler {
            try await results.value
        } onCancel: {
            results.cancel()
        }
        guard !words.isEmpty else { throw SpeechEngineError.noSpeech }
        return words
    }

    private static func collect<S: AsyncSequence>(_ sequence: S, duration: Double,
                                                  onPhase: @Sendable (Phase) -> Void) async throws -> [Word]
    where S.Element == (AttributedString, CMTimeRange) {
        var words: [Word] = []
        for try await (text, range) in sequence {
            words += Self.words(from: text, fallback: range)
            if duration > 0 { onPhase(.transcribing(min(1, range.end.seconds / duration))) }
        }
        return mergeDigitRuns(words.sorted { $0.start < $1.start })
    }

    /// Dictation models spell numbers digit by digit ("2 0 2 4"); join them back into "2024".
    static func mergeDigitRuns(_ words: [Word]) -> [Word] {
        var out: [Word] = []
        for w in words {
            if let last = out.last, last.text.allSatisfy(\.isNumber), w.text.count == 1, w.text.allSatisfy(\.isNumber),
               w.start - last.end < 0.25 {
                out[out.count - 1].text += w.text
                out[out.count - 1].end = w.end
            } else {
                out.append(w)
            }
        }
        return out
    }

    /// Splits a result into words using the per-run audio time ranges.
    static func words(from text: AttributedString, fallback: CMTimeRange) -> [Word] {
        var out: [Word] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let timeRange = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] ?? fallback
            let tokens = piece.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            let start = timeRange.start.seconds
            let end = max(timeRange.end.seconds, start + 0.05)
            let step = (end - start) / Double(tokens.count)
            for (i, token) in tokens.enumerated() {
                let isPunctuation = token.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
                if isPunctuation, !out.isEmpty {
                    out[out.count - 1].text += token
                    continue
                }
                // A run like "'t" or "'s" continues the previous word.
                if i == 0, let first = piece.first, "'’".contains(first), !out.isEmpty {
                    out[out.count - 1].text += token
                    out[out.count - 1].end = start + step
                    continue
                }
                out.append(Word(text: token, start: start + Double(i) * step, end: start + Double(i + 1) * step))
            }
        }
        return out
    }
}
