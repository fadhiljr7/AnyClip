//
//  TwoSpeakerTests.swift
//  AnyClipTests
//
//  The two-speaker stacked layout: the first-time confirmation, judging a clip
//  from the faces face tracking saw, the layout plan with its full-frame
//  fallback, swapping the two panels, and the composition that renders it.
//

import Testing
import Foundation
import AVFoundation
import CoreGraphics
import SwiftData
@testable import AnyClip

// MARK: - Synthetic face records, three frames a second like FaceTracker

private let host = FaceSpot(x: 0.25, y: 0.40, width: 0.09, height: 0.155)
private let guest = FaceSpot(x: 0.70, y: 0.38, width: 0.09, height: 0.155)
private let guestCloseUp = FaceSpot(x: 0.52, y: 0.40, width: 0.20, height: 0.35)
private let hostCloseUp = FaceSpot(x: 0.46, y: 0.42, width: 0.20, height: 0.34)
/// The host's face cut off by the right edge of a close-up of the guest.
private let hostAtEdge = FaceSpot(x: 0.98, y: 0.40, width: 0.09, height: 0.155)

private func frames(_ from: Double, _ to: Double, _ faces: [FaceSpot]) -> [ShotSample] {
    stride(from: from, to: to, by: 1.0 / 3).map { ShotSample(time: $0, faces: faces) }
}

private func analysis(_ samples: [ShotSample], cuts: [Double] = [], range: ClosedRange<Double> = 0...45) -> ShotAnalysis {
    ShotAnalysis(samples: samples, cuts: cuts, analyzed: ClipSegment(start: range.lowerBound, end: range.upperBound))
}

private let clip45 = ClipSegment(start: 0, end: 45)

private func layouts(_ segs: [LayoutSegment]) -> [String] {
    segs.map { String(format: "%@ %.1f–%.1f", $0.isStacked ? "stacked" : "full", $0.start, $0.end) }
}

// MARK: - Stage 1: first-time explanation

/// A settings domain emptied before and after the test. The name is fixed per test because macOS keeps an empty
/// file for every domain ever used.
private func withScratchDefaults(_ test: String, _ body: (UserDefaults) throws -> Void) throws {
    let name = "AnyClipTests.\(test)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
}

struct StackedIntroTests {
    @Test func turningOnExplainsOnceThenJustApplies() throws {
        try withScratchDefaults("stackedIntroOn") { defaults in
            #expect(StackedLayoutIntro.request(true, defaults: defaults) == .explain)
            // Cancel leaves nothing saved, so the explanation comes back next time.
            #expect(StackedLayoutIntro.request(true, defaults: defaults) == .explain)
            StackedLayoutIntro.confirm(defaults: defaults)
            #expect(StackedLayoutIntro.request(true, defaults: defaults) == .apply(true))
        }
    }

    @Test func turningOffNeverAsks() throws {
        try withScratchDefaults("stackedIntroOff") { defaults in
            #expect(StackedLayoutIntro.request(false, defaults: defaults) == .apply(false))
        }
    }

    @Test func projectsSavedBeforeTheOptionDecodeWithItOff() throws {
        let old = #"{"clipCount":5,"aspect":"9:16","faceTracking":true,"broll":true}"#
        let options = try JSONDecoder().decode(ProjectOptions.self, from: Data(old.utf8))
        #expect(options.stacked == false)
        #expect(ProjectOptions().stacked == false)
    }
}

// MARK: - Stage 2: what a frame shows, and the per-clip verdict

struct SpeakerViewTests {
    @Test func twoWholeFacesSideBySideAreBothSpeakers() {
        #expect(TwoSpeaker.view(of: [guest, host]) == .both(left: host, right: guest))
    }

    @Test func aFaceCutOffAtTheEdgeIsNotASecondSpeaker() {
        // Seen in the test video at 3:33: a close-up of the guest with the host's face sliced by the frame edge.
        #expect(TwoSpeaker.view(of: [guestCloseUp, hostAtEdge]) == .one(guestCloseUp))
        let medium = FaceSpot(x: 0.40, y: 0.40, width: 0.12, height: 0.23)
        #expect(TwoSpeaker.view(of: [medium, hostAtEdge]) == .one(medium))
    }

    @Test func aCloseUpWithSomeoneSmallBehindIsOneSpeaker() {
        let background = FaceSpot(x: 0.8, y: 0.3, width: 0.05, height: 0.09)
        #expect(TwoSpeaker.view(of: [guestCloseUp, background]) == .one(guestCloseUp))
    }

    @Test func groupsTinyFacesAndNoFacesAreUnclear() {
        let third = FaceSpot(x: 0.5, y: 0.4, width: 0.08, height: 0.15)
        #expect(TwoSpeaker.view(of: [host, third, guest]) == .unclear)
        #expect(TwoSpeaker.view(of: [FaceSpot(x: 0.5, y: 0.5, width: 0.03, height: 0.05)]) == .unclear)
        #expect(TwoSpeaker.view(of: []) == .unclear)
    }
}

struct SuitabilityTests {
    @Test func staticWideShotIsSuitableAndStacksTheWholeClip() {
        let a = analysis(frames(0, 45, [host, guest]))
        #expect(TwoSpeaker.suitability(a, range: clip45) == .suitable)
        let segs = TwoSpeaker.segments(a, range: clip45)
        #expect(layouts(segs) == ["stacked 0.0–45.0"])
        #expect(segs.first?.layout == .stacked(top: host, bottom: guest))
    }

    @Test func podcastThatCutsBetweenCloseUpsIsOneSpeakerAtATime() {
        var samples: [ShotSample] = []
        var cuts: [Double] = []
        for (k, start) in stride(from: 0.0, to: 45, by: 4).enumerated() {
            samples += frames(start, min(start + 4, 45), [k.isMultiple(of: 2) ? hostCloseUp : guestCloseUp])
            if start > 0 { cuts.append(start) }
        }
        let a = analysis(samples, cuts: cuts)
        #expect(TwoSpeaker.suitability(a, range: clip45) == .oneSpeaker)
        #expect(!TwoSpeaker.segments(a, range: clip45).contains { $0.isStacked })
    }

    @Test func soloMotivationalClipIsOneSpeaker() {
        let speaker = FaceSpot(x: 0.5, y: 0.35, width: 0.11, height: 0.2)
        let a = analysis(frames(0, 45, [speaker]))
        #expect(TwoSpeaker.suitability(a, range: clip45) == .oneSpeaker)
        #expect(!TwoSpeaker.suitability(a, range: clip45).allowsStacking)
    }

    @Test func wideShotsWithACloseUpAreMixedAndSwitchOnTheCuts() {
        // The example from the brief: 0–12 both, 12–18 the guest alone, 18–45 both again.
        let a = analysis(frames(0, 12, [host, guest]) + frames(12, 18, [guestCloseUp, hostAtEdge]) + frames(18, 45, [host, guest]),
                         cuts: [12.0, 18.0])
        #expect(layouts(TwoSpeaker.segments(a, range: clip45)) == ["stacked 0.0–12.0", "full 12.0–18.0", "stacked 18.0–45.0"])
        guard case .mixed(let share) = TwoSpeaker.suitability(a, range: clip45) else {
            Issue.record("expected mixed"); return
        }
        #expect(abs(share - 39.0 / 45) < 0.001)
    }

    @Test func suitableAtFirstWithACloseUpLateInTheClip() {
        let a = analysis(frames(0, 38, [host, guest]) + frames(38, 43, [guestCloseUp]) + frames(43, 45, [host, guest]),
                         cuts: [38.0, 43.0])
        #expect(layouts(TwoSpeaker.segments(a, range: clip45)) == ["stacked 0.0–38.0", "full 38.0–43.0", "stacked 43.0–45.0"])
        #expect(TwoSpeaker.suitability(a, range: clip45).allowsStacking)
    }

    @Test func briefMissedFacesDontChangeTheLayout() {
        // Two frames where one face is missed and one with none, all inside one wide shot.
        var samples = frames(0, 45, [host, guest])
        samples[30].faces = [host]
        samples[31].faces = [host]
        samples[60].faces = []
        samples[0].faces = [guest]   // even the very first frame
        let a = analysis(samples)
        #expect(layouts(TwoSpeaker.segments(a, range: clip45)) == ["stacked 0.0–45.0"])
        #expect(TwoSpeaker.suitability(a, range: clip45) == .suitable)
    }

    @Test func aSecondWithoutOneFaceAndNoCutKeepsTheStack() {
        // Seen in the test video at 20:33: the host turned away for about a second, with no camera cut.
        var samples = frames(0, 45, [host, guest])
        for k in 60..<63 { samples[k].faces = [guest] }
        let a = analysis(samples)
        #expect(layouts(TwoSpeaker.segments(a, range: clip45)) == ["stacked 0.0–45.0"])
    }

    @Test func aLongerUncutChangeIsFollowed() {
        // A graphic wiping over the host for several seconds, with no camera cut.
        let a = analysis(frames(0, 20, [host, guest]) + frames(20, 27, [guest]) + frames(27, 45, [host, guest]))
        let segs = TwoSpeaker.segments(a, range: clip45)
        #expect(segs.map(\.isStacked) == [true, false, true])
        // Without a cut to snap to, the switch lands between the last frame before the change and the first after it.
        #expect(abs(segs[1].start - 20) < 0.34 && abs(segs[1].end - 27) < 0.34)
    }

    @Test func openingGraphicsStayFullFrame() {
        let a = analysis(frames(0, 5, []) + frames(5, 45, [host, guest]), cuts: [5.0])
        #expect(layouts(TwoSpeaker.segments(a, range: clip45)) == ["full 0.0–5.0", "stacked 5.0–45.0"])
        #expect(TwoSpeaker.suitability(a, range: clip45).allowsStacking)
    }

    @Test func noUsableFacesIsInsufficient() {
        let a = analysis(frames(0, 45, []))
        #expect(TwoSpeaker.suitability(a, range: clip45) == .insufficient)
        let group = analysis(frames(0, 45, [host, FaceSpot(x: 0.5, y: 0.4, width: 0.08, height: 0.15), guest]))
        #expect(TwoSpeaker.suitability(group, range: clip45) == .insufficient)
    }

    @Test func aFewStackedSecondsArentWorthStacking() {
        let a = analysis(frames(0, 4, [host, guest]) + frames(4, 45, [guestCloseUp]), cuts: [4.0])
        #expect(TwoSpeaker.suitability(a, range: clip45) == .oneSpeaker)
    }

    @Test func trimmedPartsThatWerentCheckedAreFullFrame() {
        let a = analysis(frames(10, 40, [host, guest]), range: 10...40)
        #expect(layouts(TwoSpeaker.segments(a, range: clip45)) == ["full 0.0–10.0", "stacked 10.0–40.0", "full 40.0–45.0"])
    }

    @Test func aFalseCutInsideOneShotDoesntMoveTheCrop() {
        let a = analysis(frames(0, 45, [host, guest]), cuts: [20.0])
        #expect(layouts(TwoSpeaker.segments(a, range: clip45)) == ["stacked 0.0–45.0"])
    }

    @Test func aDifferentCameraAngleReframes() {
        let tighterHost = FaceSpot(x: 0.22, y: 0.42, width: 0.12, height: 0.21)
        let tighterGuest = FaceSpot(x: 0.76, y: 0.40, width: 0.12, height: 0.21)
        let a = analysis(frames(0, 20, [host, guest]) + frames(20, 45, [tighterHost, tighterGuest]), cuts: [20.0])
        let segs = TwoSpeaker.segments(a, range: clip45)
        #expect(layouts(segs) == ["stacked 0.0–20.0", "stacked 20.0–45.0"])
        #expect(segs.last?.layout == .stacked(top: tighterHost, bottom: tighterGuest))
    }
}

struct CutPlacementTests {
    @Test func onlyCutsThatCanChangeTheLayoutAreWorthPlacingExactly() {
        #expect(TwoSpeaker.layoutMayChange(from: [host, guest], to: [guestCloseUp]))
        #expect(TwoSpeaker.layoutMayChange(from: [], to: [host, guest]))
        #expect(!TwoSpeaker.layoutMayChange(from: [hostCloseUp], to: [guestCloseUp]))
        #expect(!TwoSpeaker.layoutMayChange(from: [], to: [guestCloseUp]))
        #expect(!TwoSpeaker.layoutMayChange(from: [host, guest], to: [host, guest]))
        let tighter = FaceSpot(x: 0.22, y: 0.42, width: 0.12, height: 0.21)
        #expect(TwoSpeaker.layoutMayChange(from: [host, guest], to: [tighter, guest]))
    }
}

struct PanelCropTests {
    let source = CGSize(width: 1920, height: 1080)
    let ratio = 1080.0 / 960.0

    @Test func eachPanelHoldsOneSpeakerAtTheSameZoom() {
        let top = TwoSpeaker.panelCrop(face: host, other: guest, anchor: TwoSpeaker.topAnchor, sourceSize: source, panelRatio: ratio)
        let bottom = TwoSpeaker.panelCrop(face: guest, other: host, anchor: TwoSpeaker.bottomAnchor, sourceSize: source, panelRatio: ratio)
        #expect(top.contains(CGPoint(x: host.x * 1920, y: host.y * 1080)))
        #expect(!top.contains(CGPoint(x: guest.x * 1920, y: guest.y * 1080)))
        #expect(bottom.contains(CGPoint(x: guest.x * 1920, y: guest.y * 1080)))
        #expect(!bottom.contains(CGPoint(x: host.x * 1920, y: host.y * 1080)))
        #expect(abs(top.height - bottom.height) < 0.001)
        #expect(abs(top.width / top.height - ratio) < 0.001)
        for crop in [top, bottom] {
            #expect(crop.minX >= 0 && crop.minY >= 0 && crop.maxX <= 1920 && crop.maxY <= 1080)
        }
    }

    @Test func speakersSittingCloseGetNarrowerPanels() {
        let near = FaceSpot(x: 0.42, y: 0.4, width: 0.09, height: 0.155)
        let crop = TwoSpeaker.panelCrop(face: host, other: near, anchor: 0.5, sourceSize: source, panelRatio: ratio)
        #expect(crop.width <= abs(host.x - near.x) * 1920 + 0.001)
    }
}

// MARK: - Clips made before the feature, and the clip-level switch

@MainActor
struct ClipStackingTests {
    func clip() -> Clip {
        Clip(index: 0, candidate: MomentCandidate(start: 0, end: 45, title: "", hook: "", summary: "", category: .story, score: 5),
             aspect: .vertical, caption: CaptionStyle(), hook: HookStyle())
    }

    @Test func clipsWithoutAnalysisBehaveAsBefore() {
        let c = clip()
        #expect(c.shots == nil)
        #expect(c.twoSpeaker == nil)
        c.stackedLayout = true
        #expect(c.stackPlan == nil)
    }

    @Test func soloClipNeverGetsAStackPlanEvenIfSwitchedOn() {
        let c = clip()
        c.shots = analysis(frames(0, 45, [FaceSpot(x: 0.5, y: 0.35, width: 0.11, height: 0.2)]))
        c.stackedLayout = true
        #expect(c.stackPlan == nil)
    }

    @Test func stackPlanNeedsTheSwitchAndNineBySixteen() {
        let c = clip()
        c.shots = analysis(frames(0, 45, [host, guest]))
        #expect(c.stackPlan == nil)
        c.setStacked(true)
        #expect(c.stackPlan?.count == 1)
        c.aspect = .square
        #expect(c.stackPlan == nil)
    }

    @Test func captionsMoveToTheSeamAndBack() {
        let c = clip()
        let presetY = c.captionStyle.positionY
        c.setStacked(true)
        #expect(c.captionStyle.positionY == TwoSpeaker.seamCaptionY)
        c.setStacked(false)
        #expect(c.captionStyle.positionY == presetY)
        // A position the user chose stays where it is.
        var style = c.captionStyle
        style.positionY = 0.85
        c.captionStyle = style
        c.setStacked(true)
        #expect(c.captionStyle.positionY == 0.85)
    }
}

// MARK: - Swapping the panels

private func stackedClip(_ analysis: ShotAnalysis, end: Double = 45) -> Clip {
    let c = Clip(index: 0, candidate: MomentCandidate(start: 0, end: end, title: "", hook: "", summary: "", category: .story, score: 5),
                 aspect: .vertical, caption: CaptionStyle(), hook: HookStyle())
    c.shots = analysis
    c.setStacked(true)
    return c
}

private func panelXs(_ plan: [LayoutSegment]?) -> [String] {
    (plan ?? []).map {
        if case .stacked(let top, let bottom) = $0.layout { String(format: "top %.2f bottom %.2f", top.x, bottom.x) } else { "full" }
    }
}

@MainActor
struct SwapSpeakersTests {
    @Test func byDefaultTheLeftSpeakerIsOnTop() {
        let c = stackedClip(analysis(frames(0, 45, [guest, host])))
        #expect(!c.stackSwapped)
        #expect(panelXs(c.stackPlan) == ["top 0.25 bottom 0.70"])
    }

    @Test func swappingPutsTheRightSpeakerOnTopWithTheSameTiming() throws {
        let c = stackedClip(analysis(frames(0, 45, [host, guest])))
        let plain = try #require(c.stackPlan)
        c.stackSwapped = true
        let swapped = try #require(c.stackPlan)
        #expect(panelXs(swapped) == ["top 0.70 bottom 0.25"])
        #expect(layouts(swapped) == layouts(plain))
        c.stackSwapped = false
        #expect(c.stackPlan == plain)
    }

    @Test func singleSpeakerPartsStayFullFrameEitherWay() throws {
        // Wide, a close-up of the guest, wide again: only the two-shots are stacked, whichever speaker is on top.
        let mixed = analysis(frames(0, 20, [host, guest]) + frames(20, 30, [guestCloseUp, hostAtEdge]) + frames(30, 45, [host, guest]),
                             cuts: [20, 30])
        let c = stackedClip(mixed)
        let plain = try #require(c.stackPlan)
        c.stackSwapped = true
        let swapped = try #require(c.stackPlan)
        #expect(layouts(swapped) == ["stacked 0.0–20.0", "full 20.0–30.0", "stacked 30.0–45.0"])
        #expect(layouts(swapped) == layouts(plain))
        #expect(swapped[1] == plain[1])
        #expect(panelXs(swapped) == ["top 0.70 bottom 0.25", "full", "top 0.70 bottom 0.25"])

        // A clip with one speaker on screen still gets no stacked layout at all.
        let solo = stackedClip(analysis(frames(0, 45, [FaceSpot(x: 0.5, y: 0.35, width: 0.11, height: 0.2)])))
        solo.stackedLayout = true
        solo.stackSwapped = true
        #expect(solo.stackPlan == nil)
    }

    @Test func theChoiceIsSavedWithTheClip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "anyclip-swap-\(UUID().uuidString).store")
        defer { for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(filePath: url.path + suffix)) } }
        let id: UUID
        do {
            let container = try ModelContainer(for: Project.self, Clip.self, configurations: ModelConfiguration(url: url))
            let c = stackedClip(analysis(frames(0, 45, [host, guest])))
            container.mainContext.insert(c)
            c.stackSwapped = true
            try container.mainContext.save()
            id = c.id
        }
        // Opening the store again, as when the editor is reopened after a restart.
        let container = try ModelContainer(for: Project.self, Clip.self, configurations: ModelConfiguration(url: url))
        let clips = try container.mainContext.fetch(FetchDescriptor<Clip>())
        let c = try #require(clips.first { $0.id == id })
        #expect(c.stackSwapped)
        #expect(c.stackedLayout)
        #expect(panelXs(c.stackPlan) == ["top 0.70 bottom 0.25"])
    }

    @Test func clipsMadeBeforeTheSettingKeepTheLeftSpeakerOnTop() {
        let c = Clip(index: 0, candidate: MomentCandidate(start: 0, end: 45, title: "", hook: "", summary: "", category: .story, score: 5),
                     aspect: .vertical, caption: CaptionStyle(), hook: HookStyle())
        #expect(!c.stackSwapped)
    }
}

// MARK: - Stage 3: the composition

/// One 1280×720 frame, red on the left half and blue on the right.
private func makeRedBlueFrame() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, nil, &buffer)
    let pb = try #require(buffer)
    CVPixelBufferLockBaseAddress(pb, [])
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let row = CVPixelBufferGetBytesPerRow(pb)
    for y in 0..<720 {
        for x in 0..<1280 {
            let p = base + y * row + x * 4
            (p[0], p[1], p[2], p[3]) = x < 640 ? (0, 0, 255, 255) : (255, 0, 0, 255)   // BGRA: red | blue
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])
    return pb
}

/// A 4-second 1280×720 video whose left half is red and right half blue: the "host" on the left, the "guest" on the right.
func makeTwoColourVideo() async throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "anyclip-twospeaker-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720])
    let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
    try writer.start()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<120 {
        _ = try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: try makeRedBlueFrame()), with: CMTime(value: CMTimeValue(frame), timescale: 30))
    }
    receiver.finish()
    await writer.finishWriting()
    return url
}

/// Red/blue of the output pixel at a point given as fractions of the frame.
private func colour(_ image: CGImage, _ fx: Double, _ fy: Double) -> (red: Int, blue: Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let x = Double(image.width) * fx, y = Double(image.height) * (1 - fy)
    ctx.draw(image, in: CGRect(x: -x, y: -y, width: Double(image.width), height: Double(image.height)))
    return (Int(px[0]), Int(px[2]))
}

struct StackedCompositionTests {
    let left = FaceSpot(x: 0.25, y: 0.45, width: 0.1, height: 0.2)
    let right = FaceSpot(x: 0.75, y: 0.45, width: 0.1, height: 0.2)

    func input(_ video: URL, stack: [LayoutSegment]?, teaser: ClipSegment? = nil) -> RenderInput {
        RenderInput(videoURL: video, audioURL: nil, start: 0, end: 4, aspect: .vertical,
                    keyframes: [.centered(at: 0)], shortSide: 360, caption: CaptionStyle(), words: [],
                    hookText: "", hook: HookStyle(), watermark: WatermarkSettings(), teaser: teaser, stack: stack)
    }

    func frame(_ built: BuiltComposition, at t: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition()
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
    }

    @Test func stacksWhereThePlanSaysAndFallsBackToFullFrame() async throws {
        let video = try await makeTwoColourVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let plan = [LayoutSegment(start: 0, end: 2, layout: .stacked(top: left, bottom: right)),
                    LayoutSegment(start: 2, end: 4, layout: .full)]
        let stacked = try await CompositionBuilder.build(input(video, stack: plan))
        let plain = try await CompositionBuilder.build(input(video, stack: nil))
        // Same length with or without stacking: nothing is added or dropped.
        #expect(stacked.duration == plain.duration)
        #expect(abs(stacked.duration - 4) < 0.05)

        // Stacked: the left speaker (red) fills the top panel, the right speaker (blue) the bottom one.
        let a = try await frame(stacked, at: 1)
        #expect(colour(a, 0.5, 0.25).red > 200 && colour(a, 0.5, 0.25).blue < 60)
        #expect(colour(a, 0.5, 0.75).blue > 200 && colour(a, 0.5, 0.75).red < 60)
        #expect(colour(a, 0.1, 0.5).red > 200 || colour(a, 0.1, 0.5).blue > 200)   // no dark seam

        // Full frame: the ordinary centred crop shows red on the left and blue on the right, top to bottom.
        let b = try await frame(stacked, at: 3)
        #expect(colour(b, 0.2, 0.75).red > 200)
        #expect(colour(b, 0.8, 0.25).blue > 200)
    }

    @Test func swappedPanelsShowTheRightSpeakerOnTop() async throws {
        let video = try await makeTwoColourVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let plan = [LayoutSegment(start: 0, end: 2, layout: .stacked(top: left, bottom: right)),
                    LayoutSegment(start: 2, end: 4, layout: .full)]
        let plain = try await CompositionBuilder.build(input(video, stack: plan))
        let swapped = try await CompositionBuilder.build(input(video, stack: plan.map(\.swapped)))
        #expect(swapped.duration == plain.duration)

        let a = try await frame(swapped, at: 1)
        #expect(colour(a, 0.5, 0.25).blue > 200 && colour(a, 0.5, 0.25).red < 60)
        #expect(colour(a, 0.5, 0.75).red > 200 && colour(a, 0.5, 0.75).blue < 60)
        #expect(colour(a, 0.1, 0.5).red > 200 || colour(a, 0.1, 0.5).blue > 200)   // no dark seam
        // The full-frame part is the same either way.
        let b = try await frame(swapped, at: 3), c = try await frame(plain, at: 3)
        for (fx, fy) in [(0.2, 0.75), (0.8, 0.25), (0.5, 0.5)] {
            #expect(colour(b, fx, fy) == colour(c, fx, fy))
        }
    }

    @MainActor @Test func previewAndExportUseTheSamePanelOrder() async throws {
        let video = try await makeTwoColourVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let container = try ModelContainer(for: Project.self, Clip.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(title: "Swap", sourceURL: nil, options: ProjectOptions())
        project.videoFileName = "source.mov"
        container.mainContext.insert(project)
        let shots = analysis(frames(0, 2, [left, right]) + frames(2, 4, [FaceSpot(x: 0.5, y: 0.4, width: 0.2, height: 0.35)]),
                             cuts: [2], range: 0...4)
        let clip = stackedClip(shots, end: 4)
        container.mainContext.insert(clip)
        clip.project = project
        clip.stackSwapped = true

        // The editor preview and the export build their input the same way, only at different sizes.
        var preview = try #require(Studio.shared.renderInput(for: clip, shortSide: PreviewController.previewShortSide))
        var export = try #require(Studio.shared.renderInput(for: clip))
        #expect(preview.stack == export.stack)
        #expect(panelXs(export.stack) == ["top 0.75 bottom 0.25", "full"])
        preview.videoURL = video; preview.audioURL = nil
        export.videoURL = video; export.audioURL = nil
        let p = try await CompositionBuilder.build(preview), e = try await CompositionBuilder.build(export)
        #expect(p.duration == e.duration)
        for built in [p, e] {
            let image = try await frame(built, at: 1)
            #expect(colour(image, 0.5, 0.25).blue > 200)
            #expect(colour(image, 0.5, 0.75).red > 200)
        }
    }

    @Test func aTeaserTakesTheLayoutOfItsOwnSourceTime() async throws {
        let video = try await makeTwoColourVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let plan = [LayoutSegment(start: 0, end: 2, layout: .full),
                    LayoutSegment(start: 2, end: 4, layout: .stacked(top: left, bottom: right))]
        let built = try await CompositionBuilder.build(input(video, stack: plan, teaser: ClipSegment(start: 3, end: 3.5)))
        #expect(abs(built.duration - 4.5) < 0.05)
        // 0.25 s into the output is the teaser (source 3.25, stacked); 1.0 s is the clip at source 0.5 (full).
        let teaser = try await frame(built, at: 0.25)
        #expect(colour(teaser, 0.5, 0.75).blue > 200 && colour(teaser, 0.5, 0.75).red < 60)
        let main = try await frame(built, at: 1.0)
        #expect(colour(main, 0.2, 0.75).red > 200)
    }
}
