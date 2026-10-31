//
//  FramingEditor.swift
//  AnyClip
//
//  Shows the whole source frame with the crop window on top. Drag the window
//  to place it; each placement becomes a keyframe at the playhead.
//

import SwiftUI
import AVFoundation
import AVKit

struct FramingEditor: View {
    @Bindable var clip: Clip
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var sourceSize = CGSize(width: 16, height: 9)
    @State private var time: Double = 0
    @State private var keyframes: [FrameKeyframe] = []
    @State private var dragStart: FrameKeyframe?
    @State private var observer: Any?
    @State private var history: [[FrameKeyframe]] = []

    private var current: FrameKeyframe { Framing.sample(keyframes, at: time) }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Adjust Framing").font(.title3.weight(.semibold))
                Spacer()
                Text("Drag the frame to place it. Each move adds a keyframe at the playhead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let videoRect = AVMakeRect(aspectRatio: sourceSize, insideRect: CGRect(origin: .zero, size: geo.size))
                let crop = Framing.cropRect(for: current, sourceSize: sourceSize, targetRatio: clip.aspect.ratio)
                let scale = videoRect.width / max(sourceSize.width, 1)
                let cropRect = CGRect(x: videoRect.minX + crop.minX * scale, y: videoRect.minY + crop.minY * scale,
                                      width: crop.width * scale, height: crop.height * scale)
                ZStack(alignment: .topLeading) {
                    PlayerLayerView(player: player)
                    // Dim everything outside the crop.
                    Path { p in
                        p.addRect(videoRect)
                        p.addRoundedRect(in: cropRect, cornerSize: CGSize(width: 6, height: 6))
                    }
                    .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.white, lineWidth: 2)
                        .background(Color.white.opacity(0.001))
                        .frame(width: cropRect.width, height: cropRect.height)
                        .offset(x: cropRect.minX, y: cropRect.minY)
                        .gesture(DragGesture().onChanged { value in
                            player.pause()
                            if dragStart == nil { dragStart = current; history.append(keyframes) }
                            guard let s = dragStart else { return }
                            var kf = s
                            kf.cx = (s.cx + value.translation.width / max(videoRect.width, 1)).clamped(to: 0...1)
                            kf.cy = (s.cy + value.translation.height / max(videoRect.height, 1)).clamped(to: 0...1)
                            upsert(kf)
                        }.onEnded { _ in dragStart = nil })
                        .pointerStyle(.grabIdle)
                        .accessibilityLabel("Crop frame")
                        .accessibilityAdjustableAction { direction in
                            history.append(keyframes)
                            var kf = current
                            kf.cx = (kf.cx + (direction == .increment ? 0.02 : -0.02)).clamped(to: 0...1)
                            upsert(kf)
                        }
                }
            }
            .background(.black)
            .clipShape(.rect(cornerRadius: 10))

            timeline

            HStack(spacing: 12) {
                Button {
                    player.rate == 0 ? player.play() : player.pause()
                } label: { Image(systemName: "playpause.fill") }
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Play or pause (Space)")
                    .accessibilityLabel("Play or Pause")
                Button("Add Keyframe", systemImage: "plus.diamond") { history.append(keyframes); upsert(current) }
                Button("Delete Keyframe", systemImage: "minus.diamond") { deleteNearest() }
                    .disabled(nearestIndex == nil)
                Button("Undo", systemImage: "arrow.uturn.backward") {
                    if let last = history.popLast() { keyframes = last }
                }
                .keyboardShortcut("z")
                .disabled(history.isEmpty)
                LabeledContent("Zoom") {
                    Slider(value: Binding(get: { current.zoom }, set: { z in
                        var kf = current
                        kf.zoom = z
                        upsert(kf)
                    }), in: 1...2.5)
                    .frame(width: 140)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    clip.keyframes = keyframes
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 860, idealWidth: 1000, minHeight: 620, idealHeight: 700)
        .task { await load() }
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer) }
            observer = nil
            player.replaceCurrentItem(with: nil)   // free the video decoder
        }
    }

    private var timeline: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let span = max(clip.duration, 0.1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.2)).frame(height: 6)
                    ForEach(keyframes) { kf in
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                            .offset(x: CGFloat((kf.time - clip.start) / span) * geo.size.width - 5.5)
                            .onTapGesture { seek(kf.time) }
                            .help("Keyframe at \(formatTimestamp(kf.time))")
                            .accessibilityLabel("Keyframe at \(formatTimestamp(kf.time))")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { seek(kf.time) }
                    }
                    Rectangle().fill(.primary).frame(width: 2, height: 18)
                        .offset(x: CGFloat((time - clip.start) / span) * geo.size.width - 1)
                }
                .frame(maxHeight: .infinity)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    seek(clip.start + Double(v.location.x / geo.size.width).clamped(to: 0...1) * span)
                })
            }
            .frame(height: 22)
            .accessibilityElement(children: .contain)
            .accessibilityValue(formatTimestamp(time))
            HStack {
                Text(formatTimestamp(clip.start))
                Spacer()
                Text(formatTimestamp(time)).foregroundStyle(.primary)
                Spacer()
                Text(formatTimestamp(clip.end))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var nearestIndex: Int? {
        keyframes.indices.min(by: { abs(keyframes[$0].time - time) < abs(keyframes[$1].time - time) })
            .flatMap { abs(keyframes[$0].time - time) < 0.4 ? $0 : nil }
    }

    private func upsert(_ kf: FrameKeyframe) {
        var k = kf
        k.time = time
        if let i = keyframes.firstIndex(where: { abs($0.time - time) < 0.15 }) {
            k.id = keyframes[i].id
            keyframes[i] = k
        } else {
            k.id = UUID()
            keyframes.append(k)
            keyframes.sort { $0.time < $1.time }
        }
    }

    private func deleteNearest() {
        guard let i = nearestIndex else { return }
        history.append(keyframes)
        keyframes.remove(at: i)
    }

    private func seek(_ t: Double) {
        time = t.clamped(to: clip.start...clip.end)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func load() async {
        keyframes = clip.keyframes
        guard let url = clip.project?.videoURL else { return }
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let geo = try? await CompositionBuilder.sourceGeometry(track) {
            sourceSize = geo.size
        }
        let item = AVPlayerItem(asset: asset)
        item.forwardPlaybackEndTime = CMTime(seconds: clip.end, preferredTimescale: 600)
        player.replaceCurrentItem(with: item)
        player.isMuted = false
        seek(clip.start)
        let start = clip.start, end = clip.end
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { t in
            MainActor.assumeIsolated {
                time = t.seconds.isFinite ? t.seconds : start
                if t.seconds >= end - 0.05 { player.pause(); seek(start) }
            }
        }
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        layer.frame = view.bounds
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.sublayers?.first?.frame = view.bounds
    }
}
