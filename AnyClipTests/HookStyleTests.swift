//
//  HookStyleTests.swift
//  AnyClipTests
//
//  Hook title looks, and where the title lands in the frame.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import AnyClip

struct HookStyleTests {
    let frame = CGSize(width: 1080, height: 1920)

    @Test func hooksSavedBeforeLooksExistedKeepTheirSettings() throws {
        let old = ##"{"enabled":false,"duration":6,"fontName":"Futura","size":0.07,"textColor":"#FF0000","boxColor":"#00FF00","uppercase":true,"positionY":0.4}"##
        let style = try JSONDecoder().decode(HookStyle.self, from: Data(old.utf8))
        #expect(!style.enabled && style.duration == 6 && style.fontName == "Futura" && style.uppercase)
        #expect(style.textColor == "#FF0000" && style.boxColor == "#00FF00" && style.positionY == 0.4)
        #expect(style.look == .card)
        #expect(style.stripColor == HookStyle().stripColor)
    }

    @Test func everyLookCanReachTheTopAndTheBottom() throws {
        for look in HookLook.allCases {
            var style = HookStyle()
            style.look = look
            let image = try #require(TextRenderer.hook("Why nobody tells you this about money", style: style, frameWidth: frame.width))
            let size = CGSize(width: image.width, height: image.height)
            let room = TextRenderer.hookRoom(style: style, frameWidth: frame.width)
            let margin = frame.width * 0.04
            style.positionY = 0
            let top = OverlayBuilder.hookFrame(imageSize: size, style: style, frameSize: frame)
            style.positionY = 1
            let bottom = OverlayBuilder.hookFrame(imageSize: size, style: style, frameSize: frame)
            // Bottom-left origin: the drawing's top edge meets the top margin, its bottom edge the bottom margin.
            #expect(abs(top.maxY - room - (frame.height - margin)) < 0.5, "\(look) top")
            #expect(abs(bottom.minY + room - margin) < 0.5, "\(look) bottom")
            #expect(top.minX + room >= 0 && top.maxX - room <= frame.width, "\(look) fits across")
        }
    }

    @Test func savedPositionsInsideTheFrameDontMove() {
        var style = HookStyle()
        style.positionY = 0.17
        let rect = OverlayBuilder.hookFrame(imageSize: CGSize(width: 800, height: 220), style: style, frameSize: frame)
        #expect(abs(rect.midY - frame.height * (1 - 0.17)) < 0.5)
    }

    @Test func sideAccentSitsOnTheLeft() throws {
        var style = HookStyle()
        style.look = .sideAccent
        let image = try #require(TextRenderer.hook("A short hook", style: style, frameWidth: frame.width))
        let rect = OverlayBuilder.hookFrame(imageSize: CGSize(width: image.width, height: image.height), style: style, frameSize: frame)
        #expect(rect.midX < frame.width / 2)
    }

    /// Writes every look at the top and bottom of a frame for eyeballing, when
    /// `TEST_RUNNER_ANYCLIP_HOOK_DIR` is set for `xcodebuild test`.
    @Test func previewImages() throws {
        guard let dir = ProcessInfo.processInfo.environment["ANYCLIP_HOOK_DIR"] else { return }
        let ctx = try #require(CGContext(data: nil, width: Int(frame.width) * 4, height: Int(frame.height), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (i, look) in HookLook.allCases.enumerated() {
            let x = CGFloat(i) * frame.width
            ctx.setFillColor(CGColor(srgbRed: 0.35 + 0.1 * CGFloat(i), green: 0.45, blue: 0.55, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: frame.width, height: frame.height))
            for position in [0.0, 0.5, 1.0] {
                var style = HookStyle()
                style.look = look
                style.positionY = position
                let image = try #require(TextRenderer.hook(position == 0.5 ? "Short hook" : "The habit that quietly makes you poor",
                                                           style: style, frameWidth: frame.width))
                let rect = OverlayBuilder.hookFrame(imageSize: CGSize(width: image.width, height: image.height), style: style, frameSize: frame)
                ctx.draw(image, in: rect.offsetBy(dx: x, dy: 0))
            }
        }
        let url = URL(filePath: dir).appending(path: "hook-looks.png")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))
    }
}
