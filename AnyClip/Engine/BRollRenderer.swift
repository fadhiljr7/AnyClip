//
//  BRollRenderer.swift
//  AnyClip
//
//  Draws B-roll cards. A still of the speaker is lifted from the video with
//  Vision, printed as a halftone with Core Image, and laid out with paper,
//  tape and type in Core Graphics. Each card has a few slightly different
//  "poses" that alternate at 8 fps for a hand-made, stop-motion feel.
//  Cards are drawn in output pixels, so preview and export match.
//

import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Vision

/// A still of the video at an insert, with the speaker cut out when Vision finds one.
nonisolated final class BRollSource: @unchecked Sendable {
    let key: String
    let still: CGImage
    /// The foreground subject with transparency, cropped to it.
    let cutout: CGImage?
    /// Largest face, normalised with a top-left origin, in the full still.
    let face: CGRect?
    /// Horizontal centre of the face within the cut-out, 0…1.
    let cutoutFaceX: CGFloat?

    init(key: String, still: CGImage, cutout: CGImage?, face: CGRect?, cutoutFaceX: CGFloat?) {
        self.key = key
        self.still = still
        self.cutout = cutout
        self.face = face
        self.cutoutFaceX = cutoutFaceX
    }
}

/// Finished card bitmaps and where they go, in output pixels with a bottom-left origin.
nonisolated final class BRollArt {
    let poses: [CGImage]
    let frame: CGRect
    init(poses: [CGImage], frame: CGRect) { self.poses = poses; self.frame = frame }
}

nonisolated enum BRollRenderer {
    static let poseCount = 3
    static let poseSeconds = 0.125

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private nonisolated(unsafe) static let sources: NSCache<NSString, BRollSource> = {
        let cache = NSCache<NSString, BRollSource>()
        cache.countLimit = 40
        return cache
    }()
    private nonisolated(unsafe) static let artCache: NSCache<NSString, BRollArt> = {
        let cache = NSCache<NSString, BRollArt>()
        cache.countLimit = 24
        return cache
    }()

    // MARK: Sources

    /// Fetches the stills the cards need. Call before building the overlay.
    static func prepare(_ input: RenderInput) async -> RenderInput {
        guard !input.broll.isEmpty else { return input }
        var out = input
        for insert in input.broll where out.brollSources[insert.id] == nil {
            let t = insert.time + min(0.4, insert.duration / 3)
            if let source = await source(video: input.videoURL, time: t) { out.brollSources[insert.id] = source }
        }
        return out
    }

    @concurrent
    static func source(video: URL, time: Double) async -> BRollSource? {
        let key = "\(video.path(percentEncoded: false))|\(Int((time * 10).rounded()))"
        if let cached = sources.object(forKey: key as NSString) { return cached }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let (still, _) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) else { return nil }

        let handler = VNImageRequestHandler(cgImage: still)
        let subject = VNGenerateForegroundInstanceMaskRequest()
        let faces = VNDetectFaceRectanglesRequest()
        try? handler.perform([subject, faces])
        var cutout: CGImage?
        if let observation = subject.results?.first,
           let buffer = try? observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                             croppedToInstancesExtent: true) {
            let image = CIImage(cvPixelBuffer: buffer)
            // Ignore specks: the subject should be a real part of the frame.
            if image.extent.width * image.extent.height > Double(still.width * still.height) * 0.04 {
                cutout = ciContext.createCGImage(image, from: image.extent)
            }
        }
        let face = faces.results?.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
            .map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
        var cutoutFaceX: CGFloat?
        if let cutout {
            let faceInCutout = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: cutout).perform([faceInCutout])
            cutoutFaceX = faceInCutout.results?.max { $0.boundingBox.width < $1.boundingBox.width }?.boundingBox.midX
        }
        let source = BRollSource(key: key, still: still, cutout: cutout, face: face, cutoutFaceX: cutoutFaceX)
        sources.setObject(source, forKey: key as NSString)
        return source
    }

    // MARK: Art

    /// Card poses and placement for one insert.
    static func art(for insert: BRollInsert, source: BRollSource?, input: RenderInput, renderSize: CGSize) -> BRollArt? {
        let W = renderSize.width, H = renderSize.height
        let key = "\(insert.hashValue)|\(Int(W))x\(Int(H))|\(source?.key ?? "-")|\(insert.kind == .overlay ? placementKey(input) : "")"
        if let cached = artCache.object(forKey: key as NSString) { return cached }
        let u = min(W, H * 9 / 16)
        let palette = BRollPalette.at(insert.palette)
        var poses: [CGImage] = []
        var frame = CGRect(origin: .zero, size: renderSize)

        switch insert.kind {
        case .full:
            for p in 0..<poseCount {
                var rng = SeededRandom(seed: UInt64(BRollPlanner.stableHash(insert.keyword)) &+ UInt64(p) &* 7919)
                let image: CGImage? = switch insert.style {
                case .poster: drawPoster(insert, source: source, size: renderSize, u: u, palette: palette, rng: &rng, pose: p)
                default: drawCollage(insert, source: source, size: renderSize, u: u, palette: palette, rng: &rng, pose: p)
                }
                if let image { poses.append(image) }
            }
        case .overlay:
            var size = CGSize.zero
            for p in 0..<poseCount {
                var rng = SeededRandom(seed: UInt64(BRollPlanner.stableHash(insert.keyword)) &+ UInt64(p) &* 104729)
                let image: CGImage? = switch insert.style {
                case .label: drawLabel(insert, u: u, palette: palette, rng: &rng)
                case .polaroid: drawPolaroid(insert, source: source, u: u, palette: palette, rng: &rng)
                default: drawNote(insert, u: u, palette: palette, rng: &rng)
                }
                if let image {
                    poses.append(image)
                    size = CGSize(width: image.width, height: image.height)
                }
            }
            frame = place(size, insert: insert, source: source, input: input, renderSize: renderSize)
        }
        guard !poses.isEmpty else { return nil }
        let art = BRollArt(poses: poses, frame: frame)
        artCache.setObject(art, forKey: key as NSString)
        return art
    }

    private static func placementKey(_ input: RenderInput) -> String {
        "\(input.caption.enabled)|\(input.caption.positionY)|\(input.caption.size)|\(input.keyframes.hashValue)|\(input.aspect.rawValue)|\(input.stack?.hashValue ?? 0)"
    }

    /// Chooses a spot for an overlay card that keeps the speaker's face and the captions clear.
    private static func place(_ size: CGSize, insert: BRollInsert, source: BRollSource?, input: RenderInput,
                              renderSize: CGSize) -> CGRect {
        let W = renderSize.width, H = renderSize.height
        var avoid: [(CGRect, CGFloat)] = []
        let stacked = input.stack?.first { insert.time >= $0.start && insert.time < $0.end && $0.isStacked }
        if let stacked, case .stacked(let top, let bottom) = stacked.layout, let source {
            // Two panels: keep both faces clear, each where its panel puts it.
            let sourceSize = CGSize(width: source.still.width, height: source.still.height)
            let half = H / 2
            for (face, other, anchor, panelTop) in [(top, bottom, TwoSpeaker.topAnchor, CGFloat(0)), (bottom, top, TwoSpeaker.bottomAnchor, half)] {
                let crop = TwoSpeaker.panelCrop(face: face, other: other, anchor: anchor, sourceSize: sourceSize, panelRatio: W / half)
                guard crop.width > 0 else { continue }
                let s = W / crop.width
                let w = face.width * sourceSize.width * s, h = face.height * sourceSize.height * s
                let cx = (face.x * sourceSize.width - crop.minX) * s, cy = panelTop + (face.y * sourceSize.height - crop.minY) * s
                // Top-left to bottom-left origin, plus hair above the face and room at the sides.
                avoid.append((CGRect(x: cx - w * 0.8, y: H - cy - h * 0.85, width: w * 1.6, height: h * 2.2), 3))
            }
        } else if let source, let face = source.face {
            let sourceSize = CGSize(width: source.still.width, height: source.still.height)
            let crop = Framing.cropRect(for: Framing.sample(input.keyframes, at: insert.time), sourceSize: sourceSize,
                                        targetRatio: input.aspect.ratio)
            if crop.width > 0 {
                let s = W / crop.width
                let px = CGRect(x: face.minX * sourceSize.width, y: face.minY * sourceSize.height,
                                width: face.width * sourceSize.width, height: face.height * sourceSize.height)
                let topLeft = CGRect(x: (px.minX - crop.minX) * s, y: (px.minY - crop.minY) * s, width: px.width * s, height: px.height * s)
                let bottomLeft = CGRect(x: topLeft.minX, y: H - topLeft.maxY, width: topLeft.width, height: topLeft.height)
                // The face plus hair above it and a little room at the sides.
                avoid.append((CGRect(x: bottomLeft.minX - bottomLeft.width * 0.3, y: bottomLeft.minY - bottomLeft.height * 0.35,
                                     width: bottomLeft.width * 1.6, height: bottomLeft.height * 2.2), 3))
            }
        } else {
            // No face found: assume the usual podcast framing, head in the upper middle.
            avoid.append((CGRect(x: W * 0.25, y: H * 0.5, width: W * 0.5, height: H * 0.3), 2))
        }
        if input.caption.enabled {
            let fontSize = CGFloat(input.caption.size) * W
            let centerY = H * (1 - CGFloat(input.caption.positionY))
            avoid.append((CGRect(x: 0, y: centerY - fontSize * 1.8, width: W, height: fontSize * 3.6), 4))
        }
        var best = CGRect(origin: CGPoint(x: (W - size.width) / 2, y: H * 0.72), size: size)
        var bestCost = CGFloat.infinity
        for (order, fy) in [0.84, 0.68, 0.52, 0.36, 0.14].enumerated() {
            for fx in [0.5, 0.27, 0.73] {
                var rect = CGRect(x: W * fx - size.width / 2, y: H * fy - size.height / 2, width: size.width, height: size.height)
                rect.origin.x = min(max(rect.minX, -size.width * 0.04), W - size.width * 0.96)
                rect.origin.y = min(max(rect.minY, H * 0.03), H * 0.97 - size.height)
                var cost = CGFloat(order) * size.width * size.height * 0.02 + (fx == 0.5 ? 0 : size.width * size.height * 0.01)
                for (area, weight) in avoid {
                    let overlap = rect.intersection(area)
                    if !overlap.isNull { cost += overlap.width * overlap.height * weight }
                }
                if cost < bestCost { bestCost = cost; best = rect }
            }
        }
        return best
    }

    // MARK: Full-screen styles

    private static func drawCollage(_ insert: BRollInsert, source: BRollSource?, size: CGSize, u: CGFloat,
                                    palette: BRollPalette, rng: inout SeededRandom, pose: Int) -> CGImage? {
        let W = size.width, H = size.height
        guard let ctx = context(size) else { return nil }
        ctx.setFillColor(TextRenderer.color(palette.background))
        ctx.fill(CGRect(origin: .zero, size: size))
        grain(ctx, size: size, u: u, rng: &rng)

        // Burst behind the speaker.
        starburst(ctx, center: CGPoint(x: W * 0.5 + rng.jitter(u * 0.006), y: H * 0.40), outer: u * 0.62, inner: u * 0.47,
                  points: 16, rotation: CGFloat(pose) * 0.05, color: TextRenderer.color(palette.accent))

        drawSpeaker(ctx, source: source, size: size, u: u, palette: palette, rng: &rng,
                    heightFraction: 0.62, paper: BRollPalette.cream, outline: "#FFFFFF")

        // Keyword on a torn strip of paper, with a misregistered print shadow.
        let word = insert.keyword.uppercased()
        let font = fitFont("Impact", text: word, maxWidth: min(u * 0.86, W * 0.9), maxSize: u * 0.19)
        let stripCenter = CGPoint(x: W * 0.5 + rng.jitter(u * 0.008), y: H * 0.80 + rng.jitter(u * 0.006))
        let angle = -0.06 + rng.jitter(0.012)
        let strip = paperLabel(ctx, text: word, font: font, center: stripCenter, angle: angle, padding: CGSize(width: u * 0.05, height: u * 0.03),
                               paper: TextRenderer.color(BRollPalette.cream), ink: TextRenderer.color(BRollPalette.ink),
                               offsetInk: TextRenderer.color(palette.accent), torn: true, u: u, rng: &rng)
        tape(ctx, center: CGPoint(x: strip.minX + u * 0.03, y: strip.maxY - u * 0.005), size: CGSize(width: u * 0.15, height: u * 0.05),
             angle: 0.6 + rng.jitter(0.08))
        tape(ctx, center: CGPoint(x: strip.maxX - u * 0.03, y: strip.minY + u * 0.005), size: CGSize(width: u * 0.15, height: u * 0.05),
             angle: 0.55 + rng.jitter(0.08))

        if !insert.lead.isEmpty {
            let lead = insert.lead.uppercased()
            let leadFont = fitFont("Avenir Next Condensed", text: lead, maxWidth: u * 0.7, maxSize: u * 0.065, weight: 0.62)
            _ = paperLabel(ctx, text: lead, font: leadFont, center: CGPoint(x: W * 0.5 - u * 0.08 + rng.jitter(u * 0.006), y: strip.maxY + u * 0.075),
                           angle: 0.045 + rng.jitter(0.01), padding: CGSize(width: u * 0.03, height: u * 0.016),
                           paper: TextRenderer.color(BRollPalette.ink), ink: TextRenderer.color(BRollPalette.cream),
                           offsetInk: nil, torn: false, u: u, rng: &rng)
        }
        // A few sparkles around, never on, the strip.
        let spots = [CGPoint(x: strip.minX - u * 0.05, y: strip.minY - u * 0.04), CGPoint(x: strip.maxX + u * 0.04, y: strip.maxY + u * 0.05),
                     CGPoint(x: strip.maxX + u * 0.02, y: strip.minY - u * 0.07)]
        for (i, spot) in spots.enumerated() {
            star(ctx, center: CGPoint(x: min(max(spot.x, u * 0.04), W - u * 0.04) + rng.jitter(u * 0.01), y: spot.y + rng.jitter(u * 0.01)),
                 radius: u * (0.022 + rng.next() * 0.015), color: TextRenderer.color(i == 1 ? BRollPalette.ink : BRollPalette.cream))
        }
        return ctx.makeImage()
    }

    private static func drawPoster(_ insert: BRollInsert, source: BRollSource?, size: CGSize, u: CGFloat,
                                   palette: BRollPalette, rng: inout SeededRandom, pose: Int) -> CGImage? {
        let W = size.width, H = size.height
        guard let ctx = context(size) else { return nil }
        ctx.setFillColor(TextRenderer.color(palette.accent))
        ctx.fill(CGRect(origin: .zero, size: size))
        grain(ctx, size: size, u: u, rng: &rng)

        // Huge keyword first, so the speaker stands in front of it like a magazine cover.
        let word = insert.keyword.uppercased()
        let lines = word.count > 9 && word.contains(" ") ? word.split(separator: " ", maxSplits: 1).map(String.init) : [word]
        let longest = lines.max { $0.count < $1.count } ?? word
        let font = fitFont("Impact", text: longest, maxWidth: W * 0.92, maxSize: u * 0.36)
        let lineHeight = CTFontGetSize(font) * 0.92
        let top = H * 0.70 + lineHeight * CGFloat(lines.count - 1) / 2
        for (i, line) in lines.enumerated() {
            let center = CGPoint(x: W / 2 + rng.jitter(u * 0.005), y: top - CGFloat(i) * lineHeight)
            drawText(ctx, line, font: font, color: TextRenderer.color(BRollPalette.ink), center: center.offset(u * 0.012, -u * 0.012), angle: 0)
            drawText(ctx, line, font: font, color: TextRenderer.color(BRollPalette.cream), center: center, angle: 0)
        }

        drawSpeaker(ctx, source: source, size: size, u: u, palette: palette, rng: &rng,
                    heightFraction: 0.64, paper: palette.background, outline: BRollPalette.cream)

        if !insert.lead.isEmpty {
            let lead = insert.lead.uppercased()
            let leadFont = fitFont("Avenir Next Condensed", text: lead, maxWidth: u * 0.7, maxSize: u * 0.06, weight: 0.62)
            _ = paperLabel(ctx, text: lead, font: leadFont, center: CGPoint(x: W / 2, y: H * 0.88 + rng.jitter(u * 0.004)),
                           angle: rng.jitter(0.012), padding: CGSize(width: u * 0.03, height: u * 0.014),
                           paper: TextRenderer.color(BRollPalette.ink), ink: TextRenderer.color(BRollPalette.cream),
                           offsetInk: nil, torn: false, u: u, rng: &rng)
        }
        // Printer's corner marks.
        ctx.setStrokeColor(TextRenderer.color(BRollPalette.ink, alpha: 0.8))
        ctx.setLineWidth(max(1, u * 0.004))
        let m = u * 0.05, l = u * 0.07
        for (x, y, dx, dy) in [(m, m, 1.0, 1.0), (W - m, m, -1.0, 1.0), (m, H - m, 1.0, -1.0), (W - m, H - m, -1.0, -1.0)] {
            ctx.move(to: CGPoint(x: x, y: y + dy * l)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + dx * l, y: y))
        }
        ctx.strokePath()
        return ctx.makeImage()
    }

    /// The halftone speaker cut-out standing at the bottom, or a taped photo when no one was found.
    private static func drawSpeaker(_ ctx: CGContext, source: BRollSource?, size: CGSize, u: CGFloat, palette: BRollPalette,
                                    rng: inout SeededRandom, heightFraction: CGFloat, paper: String, outline: String) {
        let W = size.width, H = size.height
        guard let source else { return }
        if let cutout = source.cutout {
            var h = H * heightFraction
            var w = h * CGFloat(cutout.width) / CGFloat(cutout.height)
            // Size by height; a wide subject (a mic arm, a second chair) may run off the edges.
            if w > W * 1.9 { w = W * 1.9; h = w * CGFloat(cutout.height) / CGFloat(cutout.width) }
            let scale = h / CGFloat(cutout.height)
            guard let sticker = halftone(cutout, key: source.key, dot: u / 120 / scale, ink: BRollPalette.ink, paper: paper,
                                         outline: min(40, u * 0.012 / scale), outlineColor: outline) else { return }
            let pad = (CGFloat(sticker.width) - CGFloat(cutout.width)) / 2 * scale
            // Keep the face in the middle even when the subject is lopsided.
            let faceX = source.cutoutFaceX ?? 0.5
            let left = min(max(W / 2 - w * faceX, W - w - W * 0.05), W * 0.05)
            let rect = CGRect(x: (w <= W ? (W - w) / 2 : left) - pad + rng.jitter(u * 0.006), y: -pad - H * 0.01 + rng.jitter(u * 0.004),
                              width: w + pad * 2, height: h + pad * 2)
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: rng.jitter(0.02))
            ctx.setShadow(offset: CGSize(width: u * 0.012, height: -u * 0.012), blur: u * 0.03, color: TextRenderer.color(BRollPalette.ink, alpha: 0.35))
            ctx.draw(sticker, in: CGRect(x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height))
            ctx.restoreGState()
        } else {
            photo(ctx, image: source.still, key: source.key, center: CGPoint(x: W / 2, y: H * 0.42), width: u * 0.8,
                  angle: -0.07 + rng.jitter(0.015), u: u, palette: palette, caption: nil, rng: &rng)
        }
    }

    // MARK: Overlay styles

    private static func drawNote(_ insert: BRollInsert, u: CGFloat, palette: BRollPalette, rng: inout SeededRandom) -> CGImage? {
        let word = insert.keyword.uppercased()
        let font = fitFont("Impact", text: word, maxWidth: u * 0.52, maxSize: u * 0.12)
        let leadFont = fitFont("Avenir Next Condensed", text: insert.lead.uppercased(), maxWidth: u * 0.5, maxSize: u * 0.045, weight: 0.62)
        let wordSize = textSize(word, font: font)
        let leadHeight = insert.lead.isEmpty ? 0 : CTFontGetSize(leadFont) * 1.25
        let card = CGSize(width: max(u * 0.5, wordSize.width + u * 0.1), height: wordSize.height + leadHeight + u * 0.09)
        let canvas = CGSize(width: card.width * 1.3, height: card.height * 1.55)
        guard let ctx = context(canvas) else { return nil }
        let center = CGPoint(x: canvas.width / 2 + rng.jitter(u * 0.004), y: canvas.height / 2 - u * 0.01)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: -0.05 + rng.jitter(0.014))
        let rect = CGRect(x: -card.width / 2, y: -card.height / 2, width: card.width, height: card.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: u * 0.006, height: -u * 0.01), blur: u * 0.025, color: TextRenderer.color(BRollPalette.ink, alpha: 0.4))
        ctx.addPath(tornRect(rect, u: u, rng: &rng, tornEdges: [.bottom]))
        ctx.setFillColor(TextRenderer.color(BRollPalette.cream))
        ctx.fillPath()
        ctx.restoreGState()
        // Highlighter stroke behind the lower half of the word.
        let wordCenter = CGPoint(x: 0, y: rect.minY + u * 0.045 + wordSize.height / 2)
        ctx.setFillColor(TextRenderer.color(palette.accent, alpha: 0.9))
        ctx.fill(CGRect(x: -wordSize.width / 2 - u * 0.02, y: wordCenter.y - wordSize.height * 0.42,
                        width: wordSize.width + u * 0.04, height: wordSize.height * 0.42))
        drawText(ctx, word, font: font, color: TextRenderer.color(BRollPalette.ink), center: wordCenter, angle: 0)
        if !insert.lead.isEmpty {
            drawText(ctx, insert.lead.uppercased(), font: leadFont, color: TextRenderer.color(BRollPalette.ink, alpha: 0.75),
                     center: CGPoint(x: 0, y: rect.maxY - u * 0.025 - leadHeight / 2), angle: 0)
        }
        tape(ctx, center: CGPoint(x: rng.jitter(u * 0.02), y: rect.maxY), size: CGSize(width: u * 0.16, height: u * 0.05), angle: rng.jitter(0.1))
        ctx.restoreGState()
        return ctx.makeImage()
    }

    private static func drawLabel(_ insert: BRollInsert, u: CGFloat, palette: BRollPalette, rng: inout SeededRandom) -> CGImage? {
        let word = insert.keyword.uppercased()
        let font = fitFont("Avenir Next Condensed", text: word, maxWidth: u * 0.6, maxSize: u * 0.1, weight: 0.72)
        let wordSize = textSize(word, font: font)
        let bar = CGSize(width: wordSize.width + u * 0.08, height: wordSize.height + u * 0.04)
        let leadFont = fitFont("Avenir Next Condensed", text: insert.lead.uppercased(), maxWidth: u * 0.45, maxSize: u * 0.042, weight: 0.62)
        let leadSize = textSize(insert.lead.uppercased(), font: leadFont)
        let canvas = CGSize(width: max(bar.width, leadSize.width) * 1.3 + u * 0.06, height: (bar.height + leadSize.height) * 1.7 + u * 0.05)
        guard let ctx = context(canvas) else { return nil }
        ctx.translateBy(x: canvas.width / 2 + rng.jitter(u * 0.004), y: canvas.height / 2 - u * 0.015)
        ctx.rotate(by: 0.035 + rng.jitter(0.012))
        let rect = CGRect(x: -bar.width / 2, y: -bar.height / 2, width: bar.width, height: bar.height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: u * 0.006, height: -u * 0.008), blur: u * 0.02, color: TextRenderer.color(BRollPalette.ink, alpha: 0.45))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: u * 0.012, cornerHeight: u * 0.012, transform: nil))
        ctx.setFillColor(TextRenderer.color(BRollPalette.ink))
        ctx.fillPath()
        ctx.restoreGState()
        drawText(ctx, word, font: font, color: TextRenderer.color(BRollPalette.cream), center: .zero, angle: 0)
        for x in [rect.minX, rect.maxX] {
            ctx.setFillColor(TextRenderer.color(palette.accent))
            ctx.fill(CGRect(x: x - u * 0.018, y: rect.midY - u * 0.03, width: u * 0.036, height: u * 0.06))
        }
        if !insert.lead.isEmpty {
            let tag = CGRect(x: rect.minX + u * 0.01, y: rect.maxY + u * 0.008, width: leadSize.width + u * 0.04, height: leadSize.height + u * 0.016)
            ctx.setFillColor(TextRenderer.color(palette.accent))
            ctx.fill(tag)
            drawText(ctx, insert.lead.uppercased(), font: leadFont, color: TextRenderer.color(BRollPalette.ink),
                     center: CGPoint(x: tag.midX, y: tag.midY), angle: 0)
        }
        return ctx.makeImage()
    }

    private static func drawPolaroid(_ insert: BRollInsert, source: BRollSource?, u: CGFloat, palette: BRollPalette,
                                     rng: inout SeededRandom) -> CGImage? {
        guard let source else { return drawNote(insert, u: u, palette: palette, rng: &rng) }
        let width = u * 0.36
        let canvas = CGSize(width: width * 1.45, height: width * 1.75)
        guard let ctx = context(canvas) else { return nil }
        photo(ctx, image: source.cutout ?? source.still, key: source.key + (source.cutout == nil ? "" : "-cut"),
              center: CGPoint(x: canvas.width / 2, y: canvas.height / 2), width: width, angle: 0.07 + rng.jitter(0.015),
              u: u, palette: palette, caption: insert.keyword, rng: &rng)
        return ctx.makeImage()
    }

    // MARK: Pieces

    /// A taped instant photo with a halftone print and an optional handwritten caption.
    private static func photo(_ ctx: CGContext, image: CGImage, key: String, center: CGPoint, width: CGFloat, angle: CGFloat,
                              u: CGFloat, palette: BRollPalette, caption: String?, rng: inout SeededRandom) {
        let border = width * 0.06
        let inner = width - border * 2
        let height = width + (caption == nil ? border * 1.6 : border * 3.6)
        // Centre-crop to a square.
        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: max(0, (image.height - side) / 2 - side / 8), width: side, height: side)
        guard let square = image.cropping(to: crop),
              let print = halftone(square, key: key + "-sq", dot: u / 110 / (inner / CGFloat(side)), ink: BRollPalette.ink,
                                   paper: BRollPalette.cream, outline: 0, outlineColor: nil) else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        let frame = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: u * 0.008, height: -u * 0.012), blur: u * 0.03, color: TextRenderer.color(BRollPalette.ink, alpha: 0.4))
        ctx.setFillColor(CGColor(gray: 0.99, alpha: 1))
        ctx.fill(frame)
        ctx.restoreGState()
        let photoRect = CGRect(x: frame.minX + border, y: frame.maxY - border - inner, width: inner, height: inner)
        ctx.setFillColor(TextRenderer.color(palette.background))
        ctx.fill(photoRect)
        ctx.draw(print, in: photoRect)
        if let caption {
            let font = fitFont("Marker Felt", text: caption, maxWidth: inner * 0.95, maxSize: u * 0.065, weight: 0.4)
            drawText(ctx, caption, font: font, color: TextRenderer.color(BRollPalette.ink),
                     center: CGPoint(x: 0, y: frame.minY + (photoRect.minY - frame.minY) / 2), angle: rng.jitter(0.02))
        }
        tape(ctx, center: CGPoint(x: rng.jitter(width * 0.1), y: frame.maxY), size: CGSize(width: width * 0.36, height: width * 0.1),
             angle: rng.jitter(0.12))
        ctx.restoreGState()
    }

    /// Text on a paper or tape strip; returns the strip's bounds before rotation.
    @discardableResult
    private static func paperLabel(_ ctx: CGContext, text: String, font: CTFont, center: CGPoint, angle: CGFloat, padding: CGSize,
                                   paper: CGColor, ink: CGColor, offsetInk: CGColor?, torn: Bool, u: CGFloat,
                                   rng: inout SeededRandom) -> CGRect {
        let size = textSize(text, font: font)
        let rect = CGRect(x: center.x - size.width / 2 - padding.width, y: center.y - size.height / 2 - padding.height,
                          width: size.width + padding.width * 2, height: size.height + padding.height * 2)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        let local = rect.offsetBy(dx: -center.x, dy: -center.y)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: u * 0.008, height: -u * 0.01), blur: u * 0.025, color: TextRenderer.color(BRollPalette.ink, alpha: 0.35))
        ctx.addPath(torn ? tornRect(local, u: u, rng: &rng, tornEdges: [.top, .bottom]) : CGPath(rect: local, transform: nil))
        ctx.setFillColor(paper)
        ctx.fillPath()
        ctx.restoreGState()
        if let offsetInk {
            drawText(ctx, text, font: font, color: offsetInk, center: CGPoint(x: u * 0.008, y: -u * 0.008), angle: 0)
        }
        drawText(ctx, text, font: font, color: ink, center: .zero, angle: 0)
        ctx.restoreGState()
        return rect
    }

    private enum Edge { case top, bottom }

    private static func tornRect(_ rect: CGRect, u: CGFloat, rng: inout SeededRandom, tornEdges: Set<Edge>) -> CGPath {
        let path = CGMutablePath()
        let step = u * 0.03, amp = u * 0.008
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        var x = rect.minX
        while x < rect.maxX {
            x = min(rect.maxX, x + step * (0.6 + rng.next() * 0.8))
            path.addLine(to: CGPoint(x: x, y: rect.minY + (tornEdges.contains(.bottom) ? rng.jitter(amp) : 0)))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        x = rect.maxX
        while x > rect.minX {
            x = max(rect.minX, x - step * (0.6 + rng.next() * 0.8))
            path.addLine(to: CGPoint(x: x, y: rect.maxY + (tornEdges.contains(.top) ? rng.jitter(amp) : 0)))
        }
        path.closeSubpath()
        return path
    }

    private static func tape(_ ctx: CGContext, center: CGPoint, size: CGSize, angle: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        ctx.setFillColor(TextRenderer.color(BRollPalette.tape, alpha: 0.82))
        ctx.fill(CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.18))
        ctx.fill(CGRect(x: -size.width / 2, y: 0, width: size.width, height: size.height * 0.2))
        ctx.restoreGState()
    }

    private static func starburst(_ ctx: CGContext, center: CGPoint, outer: CGFloat, inner: CGFloat, points: Int,
                                  rotation: CGFloat, color: CGColor) {
        let path = CGMutablePath()
        for i in 0..<(points * 2) {
            let r = i.isMultiple(of: 2) ? outer : inner
            let a = rotation + CGFloat(i) * .pi / CGFloat(points)
            let p = CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    private static func star(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
        starburst(ctx, center: center, outer: radius, inner: radius * 0.32, points: 4, rotation: .pi / 4, color: color)
    }

    /// Faint paper fibres.
    private static func grain(_ ctx: CGContext, size: CGSize, u: CGFloat, rng: inout SeededRandom) {
        let count = Int(size.width * size.height / (u * u) * 900)
        let dot = max(1, u / 540)
        for i in 0..<count {
            ctx.setFillColor(TextRenderer.color(i.isMultiple(of: 3) ? BRollPalette.cream : BRollPalette.ink, alpha: 0.05 + rng.next() * 0.06))
            ctx.fill(CGRect(x: rng.next() * size.width, y: rng.next() * size.height, width: dot * (1 + rng.next() * 2), height: dot))
        }
    }

    // MARK: Halftone

    private nonisolated(unsafe) static let halftones: NSCache<NSString, CGImageBox> = {
        let cache = NSCache<NSString, CGImageBox>()
        cache.countLimit = 30
        return cache
    }()

    private final class CGImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// Prints an image as dots: ink on paper. Keeps transparency and can add a sticker outline.
    private static func halftone(_ image: CGImage, key: String, dot: CGFloat, ink: String, paper: String,
                                 outline: CGFloat, outlineColor: String?) -> CGImage? {
        let cacheKey = "\(key)|\(Int(dot * 10))|\(ink)|\(paper)|\(Int(outline))|\(outlineColor ?? "")|\(image.width)x\(image.height)"
        if let cached = halftones.object(forKey: cacheKey as NSString) { return cached.image }
        let source = CIImage(cgImage: image)
        // Lift the shadows first so faces in dark rooms still read as dots, not solid ink.
        let mono = source
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.9])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.75])
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0, kCIInputContrastKey: 1.15, kCIInputBrightnessKey: 0.04,
            ])
        let dots = CIFilter.dotScreen()
        dots.inputImage = mono
        dots.center = CGPoint(x: source.extent.midX, y: source.extent.midY)
        dots.angle = 0.7
        dots.width = Float(max(dot, 2.5))
        dots.sharpness = 0.75
        guard let screened = dots.outputImage else { return nil }
        var result = screened.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(cgColor: TextRenderer.color(ink)),
            "inputColor1": CIColor(cgColor: TextRenderer.color(paper)),
        ]).cropped(to: source.extent)
        result = result.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: source,
        ])
        if outline > 0, let outlineColor {
            let canvas = source.extent.insetBy(dx: -outline * 2, dy: -outline * 2)
            let padded = source.composited(over: CIImage(color: .clear).cropped(to: canvas))
            let grown = padded.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: outline]).cropped(to: canvas)
            let ring = CIImage(color: CIColor(cgColor: TextRenderer.color(outlineColor))).cropped(to: canvas)
                .applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: grown])
            result = result.composited(over: ring).cropped(to: canvas)
        }
        guard let output = ciContext.createCGImage(result, from: result.extent) else { return nil }
        halftones.setObject(CGImageBox(output), forKey: cacheKey as NSString)
        return output
    }

    // MARK: Text

    private static func fitFont(_ family: String, text: String, maxWidth: CGFloat, maxSize: CGFloat, weight: Double = 0) -> CTFont {
        var size = maxSize
        var font = TextRenderer.font(family: family, size: size, weight: weight)
        let width = textSize(text, font: font).width
        if width > maxWidth, width > 0 {
            size = max(maxSize * 0.3, maxSize * maxWidth / width)
            font = TextRenderer.font(family: family, size: size, weight: weight)
        }
        return font
    }

    private static func line(_ text: String, font: CTFont, color: CGColor? = nil) -> CTLine {
        var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let color { attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    private static func textSize(_ text: String, font: CTFont) -> CGSize {
        let width = CTLineGetTypographicBounds(line(text, font: font), nil, nil, nil)
        return CGSize(width: CGFloat(width), height: CTFontGetCapHeight(font) * 1.0 + CTFontGetDescent(font) * 0.4)
    }

    /// Draws one line of text centred on `center` (cap-height centred, so caps look optically centred).
    private static func drawText(_ ctx: CGContext, _ text: String, font: CTFont, color: CGColor, center: CGPoint, angle: CGFloat) {
        let l = line(text, font: font, color: color)
        let width = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        if angle != 0 { ctx.rotate(by: angle) }
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: -width / 2, y: -CTFontGetCapHeight(font) / 2 + CTFontGetDescent(font) * 0.2)
        CTLineDraw(l, ctx)
        ctx.restoreGState()
    }

    private static func context(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: max(Int(size.width.rounded(.up)), 1), height: max(Int(size.height.rounded(.up)), 1),
                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

/// Deterministic randomness so a card looks the same every time it's drawn.
nonisolated struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    /// 0..<1
    mutating func next() -> CGFloat {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return CGFloat(z >> 11) / CGFloat(1 << 53)
    }

    /// -amount…amount
    mutating func jitter(_ amount: CGFloat) -> CGFloat { (next() * 2 - 1) * amount }
}

nonisolated private extension CGPoint {
    func offset(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }
}
