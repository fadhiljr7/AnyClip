//
//  ExportTests.swift
//  AnyClipTests
//
//  Rendering a real file, and what's left behind when a render fails.
//

import Testing
import Foundation
import AVFoundation
@testable import AnyClip

struct ExportTests {
    private func input(video: URL) -> RenderInput {
        RenderInput(videoURL: video, audioURL: nil, start: 0, end: 3, aspect: .vertical, keyframes: [], shortSide: 360,
                    caption: CaptionStyle(), words: [Word(text: "hello", start: 0.2, end: 0.8)], hookText: "A hook",
                    hook: HookStyle(), watermark: WatermarkSettings())
    }

    private func folderContents(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
    }

    @Test func anExportIsARealVideoAndLeavesNothingElse() async throws {
        let video = try await makeTwoColourVideo()
        let folder = FileManager.default.temporaryDirectory.appending(path: "anyclip-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: folder)
        }
        let url = folder.appending(path: "01 Clip.mp4")
        try await ClipExporter.export(input(video: video), to: url, hevc: false) { _ in }
        #expect(try folderContents(folder) == ["01 Clip.mp4"])
        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.isPlayable))
        #expect(abs(try await asset.load(.duration).seconds - 3) < 0.2)
        let track = try await #require(asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 360, height: 640))
    }

    @Test func aFailedExportKeepsTheEarlierFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "anyclip-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "01 Clip.mp4")
        try Data("the earlier export".utf8).write(to: url)
        await #expect(throws: (any Error).self) {
            try await ClipExporter.export(input(video: folder.appending(path: "missing.mp4")), to: url, hevc: false) { _ in }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "the earlier export")
        #expect(try folderContents(folder) == ["01 Clip.mp4"])
    }

    @Test func aCancelledExportKeepsTheEarlierFile() async throws {
        let video = try await makeTwoColourVideo()
        let folder = FileManager.default.temporaryDirectory.appending(path: "anyclip-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: folder)
        }
        let url = folder.appending(path: "01 Clip.mp4")
        try Data("the earlier export".utf8).write(to: url)
        let render = input(video: video)
        let task = Task { try await ClipExporter.export(render, to: url, hevc: false) { _ in } }
        task.cancel()
        _ = await task.result
        // Whether it stopped in time or just finished, a whole file is there and no partial one.
        #expect(try folderContents(folder) == ["01 Clip.mp4"])
    }
}
