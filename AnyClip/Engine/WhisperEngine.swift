//
//  WhisperEngine.swift
//  AnyClip
//
//  Whisper transcription on this Mac through WhisperKit (Core ML). Models are
//  downloaded once into Application Support and work offline afterwards.
//

import Foundation
import AVFoundation
import Observation
import Synchronization
import WhisperKit

/// Multilingual Whisper models AnyClip offers. The raw value is the folder in argmaxinc/whisperkit-coreml.
nonisolated enum WhisperModel: String, CaseIterable, Identifiable, Sendable {
    case small = "openai_whisper-small_216MB"
    case turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case turboFull = "openai_whisper-large-v3-v20240930_turbo"

    static let recommended: WhisperModel = .turbo
    static let defaultsKey = "whisperModel"

    static var selected: WhisperModel {
        WhisperModel(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .recommended
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .small: String(localized: "Small")
        case .turbo: String(localized: "Large v3 Turbo")
        case .turboFull: String(localized: "Large v3 Turbo (Full Precision)")
        }
    }

    /// Download size in megabytes.
    var megabytes: Int {
        switch self {
        case .small: 217
        case .turbo: 646
        case .turboFull: 1638
        }
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(megabytes) * 1_000_000, countStyle: .file) }

    var note: String {
        switch self {
        case .small: String(localized: "Fastest and smallest. Good for clear speech.")
        case .turbo: String(localized: "Best balance of accuracy and speed.")
        case .turboFull: String(localized: "Slightly more accurate, three times larger.")
        }
    }

    // MARK: Storage

    static let base: URL = AppPaths.support.appending(path: "WhisperKit", directoryHint: .isDirectory)
    var folder: URL { Self.base.appending(path: "models/argmaxinc/whisperkit-coreml/\(rawValue)", directoryHint: .isDirectory) }
    /// Written after a model has downloaded and loaded once, so half-finished downloads don't count.
    private var readyMarker: URL { folder.appending(path: ".anyclip-ready") }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: readyMarker.path(percentEncoded: false)) }

    func markInstalled() { FileManager.default.createFile(atPath: readyMarker.path(percentEncoded: false), contents: Data()) }
}

nonisolated enum LocalWhisperError: LocalizedError {
    case downloadFailed(String)
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let reason): String(localized: "The WhisperKit model couldn’t be downloaded. Check your internet connection and try again. (\(reason))")
        case .noSpeech: String(localized: "WhisperKit didn’t hear any speech in this video.")
        }
    }
}

/// Download state of every model, shown in New Project and Settings.
@MainActor
@Observable
final class WhisperModels {
    static let shared = WhisperModels()

    enum Activity: Equatable { case downloading(Double), preparing }

    private(set) var activity: [WhisperModel: Activity] = [:]
    private(set) var errors: [WhisperModel: String] = [:]
    /// Bumped when a model is installed or removed so views re-read `isInstalled`.
    private(set) var revision = 0
    private var tasks: [WhisperModel: Task<Void, Error>] = [:]

    func isInstalled(_ model: WhisperModel) -> Bool {
        _ = revision
        return model.isInstalled
    }

    /// Downloads and prepares a model. Calling it again while it runs waits for the same download.
    func install(_ model: WhisperModel) async throws {
        if model.isInstalled { return }
        if let running = tasks[model] { return try await running.value }
        errors[model] = nil
        activity[model] = .downloading(0)
        let task = Task {
            defer { tasks[model] = nil; activity[model] = nil; revision += 1 }
            do {
                try await WhisperEngine.install(model) { phase in
                    Task { @MainActor in
                        guard WhisperModels.shared.tasks[model] != nil else { return }
                        switch phase {
                        case .downloading(let p): WhisperModels.shared.activity[model] = .downloading(p)
                        case .preparing: WhisperModels.shared.activity[model] = .preparing
                        case .transcribing: break
                        }
                    }
                }
            } catch {
                if !(error is CancellationError) { errors[model] = error.localizedDescription }
                throw error
            }
        }
        tasks[model] = task
        try await task.value
    }

    func cancel(_ model: WhisperModel) { tasks[model]?.cancel() }

    /// Re-reads install state after a project downloaded a model.
    func refresh() { revision += 1 }

    func delete(_ model: WhisperModel) {
        tasks[model]?.cancel()
        try? FileManager.default.removeItem(at: model.folder)
        errors[model] = nil
        revision += 1
    }
}

nonisolated enum WhisperEngine {
    enum Phase: Sendable { case downloading(Double), preparing, transcribing(Double) }

    /// Downloads the model if needed and loads it once, which also fetches its tokenizer and lets
    /// Core ML compile it for this Mac. Both only happen the first time.
    @concurrent
    static func install(_ model: WhisperModel, onPhase: @Sendable @escaping (Phase) -> Void) async throws {
        if model.isInstalled { return }
        try FileManager.default.createDirectory(at: WhisperModel.base, withIntermediateDirectories: true)
        let folder: URL
        do {
            folder = try await WhisperKit.download(variant: model.rawValue, downloadBase: WhisperModel.base) { progress in
                onPhase(.downloading(progress.fractionCompleted))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw LocalWhisperError.downloadFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        onPhase(.preparing)
        let pipe = try await load(folder: folder)
        await pipe.unloadModels()
        model.markInstalled()
    }

    private static func load(folder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(modelFolder: folder.path(percentEncoded: false),
                                      tokenizerFolder: WhisperModel.base,
                                      verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: false)
        return try await WhisperKit(config)
    }

    /// Transcribes with word timings. `language` is a code like "id"; nil detects it.
    @concurrent
    static func transcribe(media: URL, language: String?, model: WhisperModel, workFolder: URL,
                           onPhase: @Sendable @escaping (Phase) -> Void) async throws -> Transcript {
        try await install(model, onPhase: onPhase)
        try Task.checkCancellation()
        onPhase(.preparing)
        let pipe = try await load(folder: model.folder)

        let wav = workFolder.appending(path: "whisper-audio.wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try await AudioExtractor.writeMono16k(from: media, to: wav)
        try Task.checkCancellation()

        let code = language.map { String($0.split(separator: "-").first ?? Substring($0)).lowercased() }
        let options = DecodingOptions(
            verbose: false, task: .transcribe, language: code,
            temperatureFallbackCount: 3, usePrefillPrompt: code != nil, detectLanguage: code == nil,
            skipSpecialTokens: true, wordTimestamps: true, chunkingStrategy: .vad)

        // Report progress and stop decoding promptly when the project is cancelled.
        let cancelled = Atomic<Bool>(false)
        let progress = pipe.progress
        let monitor = Task {
            while !Task.isCancelled {
                onPhase(.transcribing(progress.fractionCompleted))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { monitor.cancel() }
        let results = try await withTaskCancellationHandler {
            try await pipe.transcribe(audioPath: wav.path(percentEncoded: false),
                                      audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
                                      decodeOptions: options) { _ in
                cancelled.load(ordering: .relaxed) ? false : nil
            }
        } onCancel: {
            cancelled.store(true, ordering: .relaxed)
        }
        await pipe.unloadModels()
        try Task.checkCancellation()

        var words: [Word] = []
        for result in results {
            for timing in result.allWords {
                let text = timing.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !(text.hasPrefix("<|") && text.hasSuffix("|>")) else { continue }
                let end = Double(max(timing.end, timing.start + 0.05))
                // Whisper splits "anak-anak" into "anak" + "-anak" and can emit punctuation on its own.
                let isContinuation = text.hasPrefix("-") || text.allSatisfy { $0.isPunctuation }
                if isContinuation, let last = words.last, Double(timing.start) - last.end < 0.6 {
                    words[words.count - 1].text += text
                    words[words.count - 1].end = max(last.end, end)
                    continue
                }
                words.append(Word(text: text, start: Double(timing.start), end: end))
            }
        }
        words.sort { $0.start < $1.start }
        guard !words.isEmpty else { throw LocalWhisperError.noSpeech }
        let detected = results.first?.language
        return Transcript(language: code ?? detected ?? "en", words: words)
    }
}

/// Writes the audio of any audio or video file as the 16 kHz mono WAV Whisper expects.
nonisolated enum AudioExtractor {
    static func writeMono16k(from media: URL, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMAudio.sampleRate, channels: 1, interleaved: false) else {
            throw LocalWhisperError.noSpeech
        }
        let file = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: PCMAudio.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        var wroteAudio = false
        try await PCMAudio.read(media: media) { samples, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
            wroteAudio = true
        }
        guard wroteAudio else { throw LocalWhisperError.noSpeech }
    }
}
