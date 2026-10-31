//
//  ProductRulesTests.swift
//  AnyClipTests
//
//  Small rules behind the interface: trimming limits, colors, subtitle files,
//  what a project's steps show, and reading model replies and audio.
//

import Testing
import Foundation
import AVFoundation
@testable import AnyClip

struct ProductRulesTests {
    @Test func trimmingKeepsAMinimumLengthInsideTheSource() {
        #expect(ClipTrim.start(10, end: 60) == 10)
        #expect(ClipTrim.start(-4, end: 60) == 0)
        #expect(ClipTrim.start(59, end: 60) == 57)
        #expect(ClipTrim.end(50, start: 10, sourceDuration: 100) == 50)
        #expect(ClipTrim.end(11, start: 10, sourceDuration: 100) == 13)
        #expect(ClipTrim.end(500, start: 10, sourceDuration: 100) == 100)
    }

    /// These used to crash on an impossible range, e.g. when a project's duration is unknown.
    @Test func trimmingSurvivesOddClips() {
        #expect(ClipTrim.end(5, start: 10, sourceDuration: 0) == 13)
        #expect(ClipTrim.start(1, end: 2) == 0)
    }

    @Test func colorWellValuesBecomeValidHex() {
        #expect(TextRenderer.hex(red: 1, green: 0, blue: 0) == "#FF0000")
        #expect(TextRenderer.hex(red: 1.2, green: -0.1, blue: 0.5) == "#FF0080")
        // The round trip through the color well doesn't drift.
        #expect(TextRenderer.hex(red: 214.0 / 255, green: 10.0 / 255, blue: 1) == "#D60AFF")
    }

    // MARK: Subtitles

    private let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nCafé ouvert\r\n\r\n2\r\n00:00:03,500 --> 00:00:04,000\r\nsudah\r\n"

    @Test func srtFilesAreRead() {
        let words = SubtitleParser.words(fromSubtitles: srt)
        #expect(words.map(\.text) == ["Café", "ouvert", "sudah"])
        #expect(words.first?.start == 1)
        #expect(words.last?.end == 4)
    }

    @Test func subtitleFilesSavedByOtherEditorsAreRead() throws {
        for encoding in [String.Encoding.windowsCP1252, .utf16, .utf8] {
            let data = try #require(srt.data(using: encoding))
            let text = try #require(SubtitleParser.decode(data))
            #expect(SubtitleParser.words(fromSubtitles: text).first?.text == "Café", "\(encoding)")
        }
    }

    @Test func vttIsNotMistakenForSrt() {
        let words = SubtitleParser.words(fromSubtitles: "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhalo dunia\n")
        #expect(words.map(\.text) == ["halo", "dunia"])
    }

    // MARK: Project steps

    @Test func stepsNotStartedArentShownAsDone() {
        let file: [ProjectStatus] = [.transcribing, .analyzing, .framing]
        // While a file is copied in, nothing on its list has happened yet.
        #expect(StageState.of(.transcribing, current: .downloading, stages: file) == .pending)
        #expect(StageState.of(.framing, current: .queued, stages: file) == .pending)
        #expect(StageState.of(.transcribing, current: .analyzing, stages: file) == .done)
        #expect(StageState.of(.analyzing, current: .analyzing, stages: file) == .active)
        #expect(StageState.of(.framing, current: .analyzing, stages: file) == .pending)
    }

    // MARK: Model replies

    @Test func numbersAreReadHoweverTheModelWritesThem() {
        #expect(LooseJSON.int(12) == 12)
        #expect(LooseJSON.int(12.0) == 12)
        #expect(LooseJSON.int("L12", prefix: "L") == 12)
        #expect(LooseJSON.int(" 7 ") == 7)
        #expect(LooseJSON.int("soon") == nil)
        #expect(LooseJSON.int(nil) == nil)
        // A model's nonsense number must not crash the app converting it.
        #expect(LooseJSON.int(Double.infinity) == nil)
        #expect(LooseJSON.int(1e300) == nil)
    }

    @Test func aDamagedReplyGivesNoMomentsRatherThanACrash() {
        let lines = [TranscriptLine(index: 0, start: 0, end: 5, text: "Hello there.")]
        #expect(MomentFinder.parseCloud("not json", lines: lines).isEmpty)
        #expect(MomentFinder.parseCloud(#"{"clips":[{"start_line":"x"}]}"#, lines: lines).isEmpty)
        #expect(MomentFinder.parseCloud(#"{"clips":[{"start_line":1e300,"end_line":0}]}"#, lines: lines).isEmpty)
    }

    // MARK: Audio

    /// One second of silence then one of a loud tone.
    private func makeAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "anyclip-audio-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
        buffer.frameLength = 88_200
        for channel in 0..<2 {
            let samples = try #require(buffer.floatChannelData?[channel])
            for i in 0..<88_200 { samples[i] = i < 44_100 ? 0 : Float(sin(Double(i) * 0.05)) * 0.8 }
        }
        try file.write(from: buffer)
        return url
    }

    @Test func audioDecodesToMono16kHz() async throws {
        let url = try makeAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        var count = 0
        try await PCMAudio.read(media: url) { samples, _ in count += samples.count }
        #expect(abs(count - 32_000) < 1_000)
    }

    @Test func loudnessFollowsTheAudio() async throws {
        let url = try makeAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let levels = try await AudioSnap.rms(media: url, from: 0.5, to: 1.5)
        let quiet = try #require(levels.first { $0.time > 0.6 && $0.time < 0.8 })
        let loud = try #require(levels.first { $0.time > 1.2 && $0.time < 1.4 })
        #expect(quiet.level < 0.01)
        #expect(loud.level > 0.2)
        // Reading a stretch keeps its place in the file.
        #expect(abs((levels.first?.time ?? 0) - 0.5) < 0.05)
    }

    @Test func whisperAudioIsWrittenAsAWav() async throws {
        let source = try makeAudio()
        let wav = FileManager.default.temporaryDirectory.appending(path: "anyclip-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: wav)
        }
        try await AudioExtractor.writeMono16k(from: source, to: wav)
        let file = try AVAudioFile(forReading: wav)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(file.length - 32_000) < 1_000)
    }
}
