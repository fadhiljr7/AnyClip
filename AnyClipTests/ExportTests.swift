//
//  ExportTests.swift
//  AnyClipTests
//
//  Rendering a real file, and what's left behind when a render fails.
//

import Testing
import Foundation
import AVFoundation
import ImageIO
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

    @Test func theThumbnailIsTheClipsFirstFrame() async throws {
        let video = try await makeTwoColourVideo()
        let folder = FileManager.default.temporaryDirectory.appending(path: "anyclip-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: folder)
        }
        let url = folder.appending(path: "01 Thumbnail.jpg")
        try Data("an old thumbnail".utf8).write(to: url)
        try await ClipExporter.saveCover(input(video: video), to: url)
        #expect(try folderContents(folder) == ["01 Thumbnail.jpg"])
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 360 && image.height == 640)
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    }

    /// The first frame of a clip shows its hook and its first caption at once; the cover keeps only the hook.
    @Test func theThumbnailHasTheHookButNoCaptions() throws {
        let size = CGSize(width: 360, height: 640)
        let frame = try #require(CGContext(data: nil, width: 360, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)?.makeImage())
        var clip = input(video: URL(filePath: "/unused.mov"))
        clip.words = [Word(text: "CAPTION", start: 0, end: 2)]
        clip.caption.positionY = 0.5
        let cover = try #require(OverlayBuilder.cover(over: frame, input: clip, size: size))
        let hook = try #require(OverlayBuilder.hookTitle(clip, frameSize: size))
        // A black frame stays black where the caption would be, and the white hook card is drawn where it belongs.
        #expect(brightness(cover, at: CGPoint(x: 180, y: 320)) < 10)
        #expect(brightness(cover, at: CGPoint(x: hook.frame.midX, y: hook.frame.maxY - TextRenderer.hookRoom(style: clip.hook, frameWidth: 360) - 2)) > 200)
        clip.hook.enabled = false
        let plain = try #require(OverlayBuilder.cover(over: frame, input: clip, size: size))
        #expect(brightness(plain, at: CGPoint(x: hook.frame.midX, y: hook.frame.midY)) < 10)
    }

    @Test func aFailedThumbnailKeepsTheEarlierOne() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "anyclip-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "01 Thumbnail.jpg")
        try Data("the earlier thumbnail".utf8).write(to: url)
        await #expect(throws: (any Error).self) {
            try await ClipExporter.saveCover(input(video: folder.appending(path: "missing.mp4")), to: url)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "the earlier thumbnail")
        #expect(try folderContents(folder) == ["01 Thumbnail.jpg"])
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

/// Average of red, green and blue at a point, bottom-left origin.
private func brightness(_ image: CGImage, at point: CGPoint) -> Int {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -point.x, y: -point.y, width: CGFloat(image.width), height: CGFloat(image.height)))
    return (Int(px[0]) + Int(px[1]) + Int(px[2])) / 3
}
