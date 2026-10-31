//
//  TrimBar.swift
//  AnyClip
//
//  Timeline around the clip with draggable in/out handles that snap to word
//  boundaries. Speech is drawn as small bars so pauses are easy to find.
//

import SwiftUI

struct TrimBar: View {
    @Bindable var clip: Clip
    let sourceDuration: Double
    let words: [Word]
    /// Playhead in source time. Read only by the playhead mark, so playback doesn't redraw the whole bar.
    let playhead: () -> Double
    /// Where the teaser that opens the clip comes from, if it has one.
    var teaser: ClipSegment?
    var onSeek: (Double) -> Void
    var onCommit: () -> Void

    @State private var window: ClosedRange<Double>?
    @State private var dragging: Handle?
    @State private var dragOrigin: (start: Double, end: Double) = (0, 0)

    enum Handle { case start, end }

    private let handleWidth: CGFloat = 12

    private func computeWindow() -> ClosedRange<Double> {
        let pad = max(8, clip.duration * 0.6)
        let lo = max(0, clip.start - pad)
        let hi = min(max(sourceDuration, clip.end), clip.end + pad)
        return lo...max(hi, lo + 1)
    }

    var body: some View {
        let win = window ?? computeWindow()
        GeometryReader { geo in
            let width = geo.size.width
            let span = win.upperBound - win.lowerBound
            let x: (Double) -> CGFloat = { t in CGFloat((t - win.lowerBound) / span) * width }
            let time: (CGFloat) -> Double = { px in win.lowerBound + Double(px / width) * span }
            let selStart = x(clip.start), selEnd = x(clip.end)

            ZStack(alignment: .topLeading) {
                // Track with speech bars and second ticks.
                Canvas { ctx, size in
                    let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8)
                    ctx.fill(track, with: .color(.secondary.opacity(0.12)))
                    for w in words where w.end > win.lowerBound && w.start < win.upperBound {
                        let a = x(w.start), b = max(x(w.end), a + 1.5)
                        let h = size.height * (0.28 + 0.32 * min(1, Double(w.text.count) / 9))
                        let rect = CGRect(x: a, y: (size.height - h) / 2, width: b - a - 0.5, height: h)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(.secondary.opacity(0.45)))
                    }
                    if let teaser {
                        let a = x(teaser.start), b = max(x(teaser.end), a + 3)
                        let band = CGRect(x: a, y: 3, width: b - a, height: 6)
                        ctx.fill(Path(roundedRect: band, cornerRadius: 3), with: .color(.orange))
                    }
                    let step: Double = span > 120 ? 30 : (span > 40 ? 10 : 5)
                    var t = (win.lowerBound / step).rounded(.up) * step
                    while t < win.upperBound {
                        let px = x(t)
                        ctx.fill(Path(CGRect(x: px, y: size.height - 6, width: 1, height: 6)), with: .color(.secondary.opacity(0.5)))
                        t += step
                    }
                }
                .contentShape(.rect)
                .gesture(SpatialTapGesture().onEnded { value in onSeek(time(value.location.x)) })

                // Selection.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.16))
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: max(selEnd - selStart, 2), height: geo.size.height)
                    .offset(x: selStart)
                    .allowsHitTesting(false)

                handle(.start, x: selStart - handleWidth / 2, height: geo.size.height, time: time)
                handle(.end, x: selEnd - handleWidth / 2, height: geo.size.height, time: time)

                PlayheadMark(playhead: playhead, window: win, width: width, height: geo.size.height)
            }
            .coordinateSpace(.named("trim"))
        }
        .frame(height: 46)
        .overlay(alignment: .bottomLeading) {
            HStack {
                Text(formatTimestamp(win.lowerBound))
                Spacer()
                Text("\(formatTimestamp(clip.start)) – \(formatTimestamp(clip.end)) · \(formatDuration(clip.duration))")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Spacer()
                Text(formatTimestamp(win.upperBound))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .offset(y: 20)
        }
        .padding(.bottom, 20)
        .onAppear { window = computeWindow() }
        .onChange(of: clip.id) { window = computeWindow() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trim")
        .accessibilityValue(teaser.map { "\(formatTimestamp(clip.start)) to \(formatTimestamp(clip.end)), teaser from \(formatTimestamp($0.start))" }
                            ?? "\(formatTimestamp(clip.start)) to \(formatTimestamp(clip.end))")
        .accessibilityAdjustableAction { direction in
            clip.end = ClipTrim.end(clip.end + (direction == .increment ? 1 : -1), start: clip.start, sourceDuration: sourceDuration)
            onCommit()
        }
        .accessibilityAction(named: "Start One Second Earlier") {
            clip.start = ClipTrim.start(clip.start - 1, end: clip.end)
            onCommit()
        }
        .accessibilityAction(named: "Start One Second Later") {
            clip.start = ClipTrim.start(clip.start + 1, end: clip.end)
            onCommit()
        }
    }

    private func handle(_ which: Handle, x: CGFloat, height: CGFloat, time: @escaping (CGFloat) -> Double) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.accentColor)
            .frame(width: handleWidth, height: height + 6)
            .overlay {
                VStack(spacing: 2) {
                    ForEach(0..<3) { _ in Capsule().fill(.white.opacity(0.85)).frame(width: 2, height: 4) }
                }
            }
            .offset(x: x, y: -3)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("trim"))
                    .onChanged { value in
                        if dragging == nil {
                            dragging = which
                            dragOrigin = (clip.start, clip.end)
                        }
                        let raw = time(value.location.x)
                        let snapping = !NSEvent.modifierFlags.contains(.option)
                        switch which {
                        case .start:
                            let t = ClipTrim.start(raw, end: clip.end)
                            clip.start = snapping ? ClipTrim.start(snap(t, toStart: true), end: clip.end) : t
                            onSeek(clip.start)
                        case .end:
                            let t = ClipTrim.end(raw, start: clip.start, sourceDuration: sourceDuration)
                            clip.end = snapping ? ClipTrim.end(snap(t, toStart: false), start: clip.start, sourceDuration: sourceDuration) : t
                            onSeek(max(clip.start, clip.end - 1.5))
                        }
                    }
                    .onEnded { _ in
                        dragging = nil
                        window = computeWindow()
                        onCommit()
                    }
            )
            .help(which == .start ? "Drag to change where the clip starts. Hold Option to turn off snapping." :
                    "Drag to change where the clip ends. Hold Option to turn off snapping.")
    }

    private func snap(_ t: Double, toStart: Bool) -> Double {
        let candidates = words.map { toStart ? $0.start - 0.08 : $0.end + 0.25 }
        guard let nearest = candidates.min(by: { abs($0 - t) < abs($1 - t) }), abs(nearest - t) < 0.6 else { return t }
        return nearest
    }
}

/// The playhead line, in its own view so time updates during playback only redraw this.
private struct PlayheadMark: View {
    let playhead: () -> Double
    let window: ClosedRange<Double>
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let t = playhead()
        if window.contains(t) {
            Rectangle()
                .fill(.primary)
                .frame(width: 2, height: height + 8)
                .offset(x: CGFloat((t - window.lowerBound) / (window.upperBound - window.lowerBound)) * width - 1, y: -4)
                .allowsHitTesting(false)
        }
    }
}
