//
//  TextRenderer.swift
//  AnyClip
//
//  Draws captions, hook titles and text watermarks into bitmaps with Core Text.
//  Bitmaps are in output pixels, so preview and export look identical.
//

import Foundation
import CoreGraphics
import CoreText
import AppKit

nonisolated enum TextRenderer {
    static func color(_ hex: String, alpha: CGFloat = 1) -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return CGColor(gray: 1, alpha: alpha) }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        return CGColor(srgbRed: r, green: g, blue: b, alpha: a * alpha)
    }

    /// The "#RRGGBB" form of sRGB components, which color wells can report outside 0…1.
    static func hex(red: CGFloat, green: CGFloat, blue: CGFloat) -> String {
        let byte: (CGFloat) -> Int = { Int(($0.clamped(to: 0...1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    static func font(family: String, size: CGFloat, weight: Double) -> CTFont {
        var attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: family]
        if weight != 0 { attrs[kCTFontTraitsAttribute] = [kCTFontWeightTrait: weight] }
        let descriptor = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        let actual = CTFontCopyFamilyName(font) as String
        if actual.caseInsensitiveCompare(family) == .orderedSame || family.isEmpty { return font }
        // Family missing on this Mac: fall back to a heavy system font.
        return CTFontCreateUIFontForLanguage(.system, size, nil).map {
            CTFontCreateCopyWithSymbolicTraits($0, size, nil, .traitBold, .traitBold) ?? $0
        } ?? font
    }

    private struct Placed {
        var text: String
        var line: CTLine
        var width: CGFloat
        var x: CGFloat
        var baseline: CGFloat   // bottom-left origin
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func line(_ text: String, font: CTFont) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    /// Lays out words in lines no wider than `maxWidth`, centred unless `centered` is false.
    private static func layout(_ words: [String], font: CTFont, maxWidth: CGFloat, lineHeight: CGFloat,
                               pad: CGFloat, centered: Bool = true) -> (placed: [Placed], size: CGSize) {
        let space = CTLineGetTypographicBounds(line(" ", font: font), nil, nil, nil)
        var rows: [[(String, CTLine, CGFloat)]] = [[]]
        var rowWidth: CGFloat = 0
        for w in words {
            let l = line(w, font: font)
            let width = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
            let extra = rows[rows.count - 1].isEmpty ? width : width + space
            if rowWidth + extra > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([(w, l, width)])
                rowWidth = width
            } else {
                rows[rows.count - 1].append((w, l, width))
                rowWidth += extra
            }
        }
        let rowWidths = rows.map { row in row.reduce(0) { $0 + $1.2 } + space * CGFloat(max(row.count - 1, 0)) }
        let contentWidth = rowWidths.max() ?? 0
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let size = CGSize(width: ceil(contentWidth + pad * 2), height: ceil(lineHeight * CGFloat(rows.count) + pad * 2))
        var placed: [Placed] = []
        for (r, row) in rows.enumerated() {
            var x = pad + (centered ? (contentWidth - rowWidths[r]) / 2 : 0)
            // Row 0 is the top row; convert to a bottom-left baseline.
            let top = pad + lineHeight * CGFloat(r)
            let baseline = size.height - top - (lineHeight - (ascent + descent)) / 2 - ascent
            for (text, l, width) in row {
                placed.append(Placed(text: text, line: l, width: width, x: x, baseline: baseline))
                x += width + space
            }
        }
        return (placed, size)
    }

    /// One caption state. `active` is the word being spoken (nil = none).
    static func caption(words rawWords: [String], active: Int?, style: CaptionStyle, frameWidth: CGFloat) -> CGImage? {
        guard !rawWords.isEmpty else { return nil }
        let words = style.uppercase ? rawWords.map { $0.uppercased() } : rawWords
        let fontSize = CGFloat(style.size) * frameWidth
        let font = font(family: style.fontName, size: fontSize, weight: style.fontWeight)
        let stroke = CGFloat(style.strokeWidth) * fontSize
        let glow = style.glow ? fontSize * 0.45 : 0
        let boxPad = style.highlight == .box ? fontSize * 0.16 : 0
        let pad = ceil(stroke + glow + boxPad + fontSize * 0.25)
        let lineHeight = fontSize * 1.16
        let (placed, size) = layout(words, font: font, maxWidth: frameWidth * 0.86, lineHeight: lineHeight, pad: pad)
        guard let ctx = makeContext(width: Int(size.width), height: Int(size.height)) else { return nil }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let text = color(style.textColor), hi = color(style.highlightColor), strokeColor = color(style.strokeColor)

        func isLit(_ i: Int) -> Bool {
            guard let active else { return false }
            switch style.highlight {
            case .color, .box: return i == active
            case .karaoke: return i <= active
            case .none: return false
            }
        }

        // Highlight box behind the active word.
        if style.highlight == .box, let active, active < placed.count {
            let p = placed[active]
            let rect = CGRect(x: p.x - boxPad * 1.3, y: p.baseline - descent - boxPad * 0.7,
                              width: p.width + boxPad * 2.6, height: ascent + descent + boxPad * 1.4)
            ctx.saveGState()
            if style.shadow { ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.05), blur: fontSize * 0.2, color: CGColor(gray: 0, alpha: 0.45)) }
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: fontSize * 0.2, cornerHeight: fontSize * 0.2, transform: nil))
            ctx.setFillColor(hi)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Outline pass (with drop shadow) underneath everything.
        if stroke > 0 {
            ctx.saveGState()
            if style.shadow { ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.06), blur: fontSize * 0.16, color: CGColor(gray: 0, alpha: 0.55)) }
            ctx.setTextDrawingMode(.stroke)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(stroke * 2)
            ctx.setStrokeColor(strokeColor)
            for (i, p) in placed.enumerated() where !(style.highlight == .box && i == active) {
                ctx.textPosition = CGPoint(x: p.x, y: p.baseline)
                CTLineDraw(p.line, ctx)
            }
            ctx.restoreGState()
        }

        // Fill pass.
        for (i, p) in placed.enumerated() {
            ctx.saveGState()
            let lit = isLit(i)
            let fill = (lit && style.highlight != .box) ? hi : text
            if lit, style.glow {
                ctx.setShadow(offset: .zero, blur: glow, color: hi)
            } else if stroke == 0, style.shadow {
                ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.05), blur: fontSize * 0.22, color: CGColor(gray: 0, alpha: 0.75))
            }
            ctx.setTextDrawingMode(.fill)
            ctx.setFillColor(fill)
            // CTLineDraw advances the text position, so set it before every pass.
            ctx.textPosition = CGPoint(x: p.x, y: p.baseline)
            CTLineDraw(p.line, ctx)
            if lit, style.glow {
                // Second glow pass makes the halo read; a final pass without shadow keeps letters crisp.
                ctx.textPosition = CGPoint(x: p.x, y: p.baseline)
                CTLineDraw(p.line, ctx)
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                ctx.textPosition = CGPoint(x: p.x, y: p.baseline)
                CTLineDraw(p.line, ctx)
            }
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    /// Transparent room around a hook title's drawing, for its shadow, outline and tilt.
    static func hookRoom(style: HookStyle, frameWidth: CGFloat) -> CGFloat {
        ceil(CGFloat(style.size) * frameWidth * 0.6)
    }

    /// Hook title in one of the looks. The drawing is surrounded by `hookRoom` on every side.
    static func hook(_ raw: String, style: HookStyle, frameWidth: CGFloat) -> CGImage? {
        let textValue = style.uppercase ? raw.uppercased() : raw
        let words = textValue.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nil }
        let fontSize = CGFloat(style.size) * frameWidth
        let font = font(family: style.fontName, size: fontSize, weight: 0.56)
        let room = hookRoom(style: style, frameWidth: frameWidth)
        switch style.look {
        case .card: return hookCard(words, style: style, font: font, fontSize: fontSize, frameWidth: frameWidth, room: room)
        case .strip: return hookStrip(words, style: style, font: font, fontSize: fontSize, frameWidth: frameWidth, room: room)
        case .sideAccent: return hookSideAccent(words, style: style, font: font, fontSize: fontSize, frameWidth: frameWidth, room: room)
        case .outline: return hookOutline(words, style: style, font: font, fontSize: fontSize, frameWidth: frameWidth, room: room)
        }
    }

    private static func draw(_ placed: [Placed], in ctx: CGContext, offset: CGPoint) {
        for p in placed {
            // CTLineDraw advances the text position, so set it for every line.
            ctx.textPosition = CGPoint(x: offset.x + p.x, y: offset.y + p.baseline)
            CTLineDraw(p.line, ctx)
        }
    }

    /// Dark text on a rounded card.
    private static func hookCard(_ words: [String], style: HookStyle, font: CTFont, fontSize: CGFloat,
                                 frameWidth: CGFloat, room: CGFloat) -> CGImage? {
        let padX = fontSize * 0.7, padY = fontSize * 0.42
        let (placed, inner) = layout(words, font: font, maxWidth: frameWidth * 0.78, lineHeight: fontSize * 1.18, pad: 0)
        let card = CGSize(width: inner.width + padX * 2, height: inner.height + padY * 2)
        guard let ctx = makeContext(width: Int(ceil(card.width + room * 2)), height: Int(ceil(card.height + room * 2))) else { return nil }
        let rect = CGRect(x: room, y: room, width: card.width, height: card.height)
        let radius = min(fontSize * CGFloat(style.cornerRadius), card.height / 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.12), blur: fontSize * 0.5, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color(style.boxColor))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setFillColor(color(style.textColor))
        draw(placed, in: ctx, offset: CGPoint(x: rect.minX + padX, y: rect.minY + padY))
        return ctx.makeImage()
    }

    /// Each line on its own marker-style strip, optionally tilted like a sticker.
    private static func hookStrip(_ words: [String], style: HookStyle, font: CTFont, fontSize: CGFloat,
                                  frameWidth: CGFloat, room: CGFloat) -> CGImage? {
        let padX = fontSize * 0.38
        let lineHeight = fontSize * 1.42
        let (placed, inner) = layout(words, font: font, maxWidth: frameWidth * 0.78, lineHeight: lineHeight, pad: 0)
        let content = CGSize(width: inner.width + padX * 2, height: inner.height)
        let size = CGSize(width: ceil(content.width + room * 2), height: ceil(content.height + room * 2))
        guard let ctx = makeContext(width: Int(size.width), height: Int(size.height)) else { return nil }
        if style.stripTilt {
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: 2 * .pi / 180)
            ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        }
        let origin = CGPoint(x: room + padX, y: room)
        // Strips hug the capitals rather than the font's full line box, so stacked lines keep a small gap.
        let below = fontSize * 0.34, above = CTFontGetCapHeight(font) + fontSize * 0.26
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.08), blur: fontSize * 0.3, color: CGColor(gray: 0, alpha: 0.3))
        ctx.setFillColor(color(style.stripColor))
        for row in Dictionary(grouping: placed, by: \.baseline).values {
            let minX = row.map(\.x).min() ?? 0, maxX = row.map { $0.x + $0.width }.max() ?? 0
            let baseline = origin.y + row[0].baseline
            ctx.fill(CGRect(x: origin.x + minX - padX, y: baseline - below, width: maxX - minX + padX * 2, height: below + above))
        }
        ctx.restoreGState()
        ctx.setFillColor(color(style.stripTextColor))
        draw(placed, in: ctx, offset: origin)
        return ctx.makeImage()
    }

    /// Left-aligned text beside a bold accent bar, on an optional dark backdrop.
    private static func hookSideAccent(_ words: [String], style: HookStyle, font: CTFont, fontSize: CGFloat,
                                       frameWidth: CGFloat, room: CGFloat) -> CGImage? {
        let bar = fontSize * 0.16, gap = fontSize * 0.5
        let pad = style.accentBackdrop ? fontSize * 0.45 : 0
        let (placed, inner) = layout(words, font: font, maxWidth: frameWidth * 0.72, lineHeight: fontSize * 1.18, pad: 0,
                                     centered: false)
        let block = CGSize(width: bar + gap + inner.width + pad * 2, height: inner.height + pad * 2)
        guard let ctx = makeContext(width: Int(ceil(block.width + room * 2)), height: Int(ceil(block.height + room * 2))) else { return nil }
        let rect = CGRect(x: room, y: room, width: block.width, height: block.height)
        if style.accentBackdrop {
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: fontSize * 0.25, cornerHeight: fontSize * 0.25, transform: nil))
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
            ctx.fillPath()
        }
        ctx.saveGState()
        if !style.accentBackdrop {
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.06), blur: fontSize * 0.35, color: CGColor(gray: 0, alpha: 0.6))
        }
        let barRect = CGRect(x: rect.minX + pad, y: rect.minY + pad, width: bar, height: inner.height)
        ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: bar / 2, cornerHeight: bar / 2, transform: nil))
        ctx.setFillColor(color(style.accentColor))
        ctx.fillPath()
        ctx.setFillColor(color(style.accentTextColor))
        draw(placed, in: ctx, offset: CGPoint(x: barRect.maxX + gap, y: rect.minY + pad))
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Big outlined letters with no box, like a thumbnail title.
    private static func hookOutline(_ words: [String], style: HookStyle, font: CTFont, fontSize: CGFloat,
                                    frameWidth: CGFloat, room: CGFloat) -> CGImage? {
        let stroke = fontSize * CGFloat(style.outlineWidth)
        let (placed, inner) = layout(words, font: font, maxWidth: frameWidth * 0.84, lineHeight: fontSize * 1.14, pad: 0)
        guard let ctx = makeContext(width: Int(ceil(inner.width + room * 2)), height: Int(ceil(inner.height + room * 2))) else { return nil }
        let origin = CGPoint(x: room, y: room)
        if stroke > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.08), blur: fontSize * 0.3, color: CGColor(gray: 0, alpha: 0.45))
            ctx.setLineJoin(.round)
            // The stroke is centred on the outline, so draw it twice as wide and cover the inner half with the fill.
            ctx.setLineWidth(stroke * 2)
            ctx.setStrokeColor(color(style.outlineColor))
            ctx.setTextDrawingMode(.stroke)
            draw(placed, in: ctx, offset: origin)
            ctx.restoreGState()
        } else {
            ctx.setShadow(offset: CGSize(width: 0, height: -fontSize * 0.06), blur: fontSize * 0.35, color: CGColor(gray: 0, alpha: 0.6))
        }
        ctx.setTextDrawingMode(.fill)
        ctx.setFillColor(color(style.outlineTextColor))
        draw(placed, in: ctx, offset: origin)
        return ctx.makeImage()
    }

    static func watermarkText(_ text: String, frameWidth: CGFloat, size: Double) -> CGImage? {
        guard !text.isEmpty else { return nil }
        let fontSize = max(14, CGFloat(size) * frameWidth * 0.25)
        let font = font(family: "Avenir Next", size: fontSize, weight: 0.4)
        let (placed, sz) = layout([text], font: font, maxWidth: frameWidth, lineHeight: fontSize * 1.2, pad: fontSize * 0.4)
        guard let ctx = makeContext(width: Int(sz.width), height: Int(sz.height)) else { return nil }
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: fontSize * 0.25, color: CGColor(gray: 0, alpha: 0.6))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for p in placed {
            ctx.textPosition = CGPoint(x: p.x, y: p.baseline)
            CTLineDraw(p.line, ctx)
        }
        return ctx.makeImage()
    }

    static func image(at path: String) -> CGImage? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
