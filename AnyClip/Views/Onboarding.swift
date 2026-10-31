//
//  Onboarding.swift
//  AnyClip
//
//  A guided tour that dims the window and spotlights real controls one at a
//  time. Views opt in with `.tourTarget(_:)`; their on-screen frames are read
//  from AppKit so the spotlight follows them across split-view columns,
//  scroll views and window resizes.
//

import SwiftUI
import SwiftData

enum TourTarget: Hashable {
    case sidebarNewProject, sidebarProjects, sidebarLibrary
    case videoSource, clipOptions, styleOptions, aiProvider, createButton
    case firstClip, editorPreview, trimBar, inspector
}

struct TourStep: Identifiable {
    enum Screen { case create, keep, project, editor, library, restore }

    let id: String
    var target: TourTarget?
    let screen: Screen
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
}

@MainActor
@Observable
final class Onboarding {
    static let shared = Onboarding()
    static let completedKey = "onboardingCompleted"

    private(set) var isActive = false
    private(set) var steps: [TourStep] = []
    private(set) var index = 0
    /// The current target's frame in the overlay's coordinate space, or nil when it isn't on screen.
    private(set) var spotlight: CGRect?
    /// False for a moment after a step changes, while its target view appears.
    private(set) var cardReady = false
    /// Set by Settings or the Help menu; the main window starts the tour when it sees it.
    var pendingStart = false

    @ObservationIgnored private let anchors = NSHashTable<TourAnchorView>.weakObjects()
    @ObservationIgnored weak var host: NSView?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var stepShownAt = Date()
    @ObservationIgnored private var scrolledForStep = -1
    @ObservationIgnored private var demoProject: UUID?
    @ObservationIgnored private var demoClip: Clip?
    @ObservationIgnored private var restoreSelection: SidebarItem?
    @ObservationIgnored private var restorePath: [Clip] = []

    var current: TourStep? { steps.indices.contains(index) ? steps[index] : nil }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == steps.count - 1 }

    static var hasCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    /// Shows the tour on first launch only.
    func startIfNeeded(projects: [Project]) {
        if pendingStart || !Self.hasCompleted { start(projects: projects) }
    }

    func requestStart() { pendingStart = true }

    /// From Settings or the Help menu: close Settings, bring the main window forward and start.
    static func showTour(openWindow: OpenWindowAction) {
        let settings = NSApp.windows.filter { $0.identifier?.rawValue.contains("Settings") == true }
        settings.forEach { $0.close() }
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            main.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        shared.requestStart()
    }

    func start(projects: [Project]) {
        pendingStart = false
        guard !isActive else { return }
        let state = AppState.shared
        restoreSelection = state.selection
        restorePath = state.path
        let demo = projects.first { $0.status == .ready && !$0.clips.isEmpty }
            ?? projects.first { !$0.clips.isEmpty }
        demoProject = demo?.id
        demoClip = demo?.sortedClips.first
        steps = Self.makeSteps(hasClips: demo != nil)
        index = 0
        isActive = true
        state.columnVisibility = .all
        show()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { Onboarding.shared.measure() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func next() {
        guard isActive else { return }
        if isLast { finish() } else { index += 1; show() }
    }

    func previous() {
        guard isActive, index > 0 else { return }
        index -= 1
        show()
    }

    /// Ends the tour, whether it was completed or skipped. It won't come back on its own.
    func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        timer?.invalidate()
        timer = nil
        isActive = false
        spotlight = nil
        let state = AppState.shared
        if state.selection != restoreSelection { state.selection = restoreSelection }
        let path = restorePath
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { AppState.shared.path = path }
        demoClip = nil
    }

    // MARK: Anchors

    func register(_ view: TourAnchorView) { anchors.add(view) }

    #if DEBUG
    func dump() {
        for w in NSApp.windows { FileHandle.standardError.write(Data("[tour] window \(w.identifier?.rawValue ?? "-") visible=\(w.isVisible)\n".utf8)) }
        for v in anchors.allObjects {
            var chain: [String] = []
            var s = v.superview
            while let x = s, chain.count < 4 { chain.append(String(describing: type(of: x))); s = x.superview }
            FileHandle.standardError.write(Data("[tour] \(String(describing: v.target)) frame=\(v.frame) vis=\(v.visibleRect) win=\(v.convert(v.bounds, to: nil)) \(chain)\n".utf8))
        }
    }
    #endif
    func unregister(_ view: TourAnchorView) { anchors.remove(view) }

    private func show() {
        guard let step = current else { return }
        stepShownAt = Date()
        cardReady = step.target == nil
        navigate(for: step.screen)
        host?.window?.makeFirstResponder(nil)
        measure()
    }

    private func navigate(for screen: TourStep.Screen) {
        let state = AppState.shared
        func select(_ item: SidebarItem) { if state.selection != item { state.selection = item } }
        switch screen {
        case .keep:
            break
        case .create:
            select(.create)
            state.path = []
        case .library:
            select(.allClips)
            state.path = []
        case .project:
            if let demoProject { select(.project(demoProject)) }
            state.path = []
        case .editor:
            guard let demoProject, let demoClip else { return }
            select(.project(demoProject))
            // Changing the selection clears the path, so push the editor after that settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if AppState.shared.path.last?.id != demoClip.id { AppState.shared.path = [demoClip] }
            }
        case .restore:
            select(.create)
            state.path = []
        }
    }

    private func measure() {
        guard isActive, let step = current else { return }
        guard let target = step.target, let host, let window = host.window else {
            if spotlight != nil { spotlight = nil }
            return
        }
        let matches = anchors.allObjects.filter {
            $0.target == target && $0.window === window && !$0.isHiddenOrHasHiddenAncestor
        }
        // Bring a target inside a scroll view into view once per step.
        if scrolledForStep != index, !matches.isEmpty, Date().timeIntervalSince(stepShownAt) > 0.25 {
            scrolledForStep = index
            Self.center(matches)
        }
        // `visibleRect` isn't reliable inside SwiftUI hosting views, so clip to each enclosing scroll view.
        var union: CGRect?
        for view in matches {
            var r = view.convert(view.bounds, to: nil)
            var scroll = view.enclosingScrollView
            while let sv = scroll, !r.isNull {
                r = r.intersection(sv.contentView.convert(sv.contentView.bounds, to: nil))
                scroll = sv.enclosingScrollView
            }
            guard !r.isNull, r.width > 2, r.height > 2 else { continue }
            union = union.map { $0.union(r) } ?? r
        }
        let hostRect = host.convert(host.bounds, to: nil)
        let local = union.map {
            CGRect(x: $0.minX - hostRect.minX, y: hostRect.maxY - $0.maxY, width: $0.width, height: $0.height)
        }
        if !Self.nearlyEqual(local, spotlight) { spotlight = local }
        let ready = local != nil || Date().timeIntervalSince(stepShownAt) > 1.2
        if ready != cardReady { cardReady = ready }
    }

    /// Scrolls so the targets sit in the middle of their scroll view (or at its top when they're taller).
    private static func center(_ views: [TourAnchorView]) {
        guard let sv = views.first?.enclosingScrollView, let doc = sv.documentView else { return }
        let rect = views.filter { $0.enclosingScrollView === sv }
            .map { $0.convert($0.bounds, to: doc) }
            .reduce(CGRect.null) { $0.union($1) }
        let clip = sv.contentView
        let visible = clip.bounds.height
        guard !rect.isNull, doc.frame.height > visible else { return }
        var y = rect.height < visible - 40 ? rect.midY - visible / 2 : (doc.isFlipped ? rect.minY - 20 : rect.maxY + 20 - visible)
        y = min(max(y, 0), doc.frame.height - visible)
        if abs(y - clip.bounds.origin.y) < 1 { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        }
        sv.reflectScrolledClipView(clip)
    }

    private static func nearlyEqual(_ a: CGRect?, _ b: CGRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
        default: false
        }
    }

    // MARK: Steps

    private static func makeSteps(hasClips: Bool) -> [TourStep] {
        var steps: [TourStep] = [
            TourStep(id: "welcome", target: nil, screen: .create, icon: "sparkles.rectangle.stack",
                     title: "Welcome to AnyClip",
                     message: "Turn long videos into short, captioned clips — free, private and right on your Mac. This quick tour shows you how it works."),
            TourStep(id: "new", target: .sidebarNewProject, screen: .create, icon: "plus.square.on.square",
                     title: "Every clip starts here",
                     message: "Choose New Project in the sidebar, or press ⌘N from anywhere, to start with a new video."),
            TourStep(id: "source", target: .videoSource, screen: .create, icon: "link",
                     title: "Add a video",
                     message: "Paste a YouTube, TikTok, Instagram or X link, choose a file, or drop a video onto the window. Already have subtitles? Attach them to skip transcription."),
            TourStep(id: "options", target: .clipOptions, screen: .create, icon: "slider.horizontal.3",
                     title: "Shape your clips",
                     message: "Pick how many clips you want, how long they are and their format. Keep faces in frame follows the speaker, and Focus tells the AI what to look for."),
            TourStep(id: "style", target: .styleOptions, screen: .create, icon: "captions.bubble",
                     title: "Choose a look",
                     message: "Pick a caption style, add a hook title that grabs attention in the first seconds, and export everything automatically when it’s done."),
            TourStep(id: "ai", target: .aiProvider, screen: .create, icon: "apple.intelligence",
                     title: "Who picks the moments",
                     message: "Apple Intelligence finds the best moments privately on this Mac. Prefer Gemini, OpenAI or another service? Add your own key in Settings › AI."),
            TourStep(id: "create", target: .createButton, screen: .create, icon: "wand.and.stars",
                     title: "Create your clips",
                     message: "AnyClip downloads, transcribes, finds the best moments and frames them for you. It works in the background, so you can keep going."),
            TourStep(id: "projects", target: .sidebarProjects, screen: .keep, icon: "folder",
                     title: "Your projects",
                     message: "Each video becomes a project here, with live progress while it works. Control-click a project to try again, show it in Finder or delete it."),
        ]
        if hasClips {
            steps += [
                TourStep(id: "clips", target: .firstClip, screen: .project, icon: "square.grid.2x2",
                         title: "Review your clips",
                         message: "Clips are scored and sorted best first. Each card shows its score, length and hook. Click a clip to open it in the editor."),
                TourStep(id: "preview", target: .editorPreview, screen: .editor, icon: "play.rectangle",
                         title: "See exactly what you’ll export",
                         message: "Captions, hook, watermark and framing play live here. Press Space to play or pause."),
                TourStep(id: "trim", target: .trimBar, screen: .editor, icon: "timeline.selection",
                         title: "Trim to the word",
                         message: "Drag the handles to change where the clip starts and ends. They snap to spoken words, so sentences never get cut off."),
                TourStep(id: "inspector", target: .inspector, screen: .editor, icon: "slider.vertical.3",
                         title: "Fine-tune everything",
                         message: "Edit caption text and style, rewrite the hook, adjust framing with keyframes and see why the clip was chosen. Export with ⌘E."),
            ]
        } else {
            steps.append(TourStep(id: "editor", target: nil, screen: .keep, icon: "slider.horizontal.below.rectangle",
                                  title: "Fine-tune any clip",
                                  message: "When your clips are ready, open one to trim it on word boundaries, edit captions and the hook, adjust framing with keyframes, then export with ⌘E."))
        }
        steps += [
            TourStep(id: "library", target: .sidebarLibrary, screen: .library, icon: "rectangle.stack",
                     title: "All your clips in one place",
                     message: "Browse every clip from every project. Hot collects the highest-scoring ones, and Saved keeps the clips you bookmark with ⌘D."),
            TourStep(id: "done", target: nil, screen: .restore, icon: "checkmark.seal",
                     title: "You’re all set",
                     message: "Settings (⌘,) has dark mode, export quality, AI keys, your watermark and download tools. You can repeat this tour any time from Settings › General."),
        ]
        return steps
    }
}

// MARK: - Anchors

final class TourAnchorView: NSView {
    var target: TourTarget?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { Onboarding.shared.unregister(self) } else { Onboarding.shared.register(self) }
    }
}

private struct TourAnchor: NSViewRepresentable {
    let target: TourTarget

    func makeNSView(context: Context) -> TourAnchorView {
        let view = TourAnchorView()
        view.target = target
        return view
    }

    func updateNSView(_ view: TourAnchorView, context: Context) { view.target = target }
}

/// Measures the overlay itself so target frames can be converted into it.
private final class TourHostView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Onboarding.shared.host = self }
    }
}

private struct TourHost: NSViewRepresentable {
    func makeNSView(context: Context) -> TourHostView { TourHostView() }
    func updateNSView(_ view: TourHostView, context: Context) {}
}

extension View {
    /// Marks this view as something the tour can spotlight. Several views may share a target;
    /// the spotlight covers all of them.
    func tourTarget(_ target: TourTarget) -> some View {
        background(TourAnchor(target: target))
    }
}

// MARK: - Overlay

struct OnboardingOverlay: View {
    private let tour = Onboarding.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardSize = CGSize(width: 340, height: 220)

    var body: some View {
        if tour.isActive, let step = tour.current {
            GeometryReader { geo in
                let bounds = CGRect(origin: .zero, size: geo.size)
                let hole = tour.spotlight.map { $0.insetBy(dx: -8, dy: -8).intersection(bounds.insetBy(dx: 2, dy: 2)) }
                let closed = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
                let origin = Self.cardOrigin(hole: hole, card: cardSize, in: bounds)

                ZStack(alignment: .topLeading) {
                    SpotlightShape(hole: hole ?? closed)
                        .fill(.black.opacity(0.52), style: FillStyle(eoFill: true))
                        // Clicks outside the spotlight are absorbed; the highlighted control stays usable.
                        .contentShape(SpotlightShape(hole: hole ?? closed), eoFill: true)
                        .onTapGesture {}
                        .accessibilityHidden(true)

                    if let hole {
                        SpotlightRing(pulse: !reduceMotion)
                            .frame(width: hole.width, height: hole.height)
                            .offset(x: hole.minX, y: hole.minY)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    TourCard(step: step)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                        .offset(x: origin.x, y: origin.y)
                        .opacity(tour.cardReady ? 1 : 0)
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.45), value: hole)
                .animation(.easeInOut(duration: 0.2), value: tour.cardReady)
            }
            .background(TourHost())
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    /// Beside the spotlight when there's room (right, left, below, above), otherwise inside it.
    static func cardOrigin(hole: CGRect?, card: CGSize, in bounds: CGRect) -> CGPoint {
        let margin: CGFloat = 16, gap: CGFloat = 18
        guard let h = hole, !h.isEmpty else {
            return CGPoint(x: bounds.midX - card.width / 2, y: bounds.midY - card.height / 2)
        }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, bounds.minX + margin), bounds.maxX - margin - card.width) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, bounds.minY + margin + 40), bounds.maxY - margin - card.height) }
        if h.maxX + gap + card.width + margin <= bounds.maxX {
            return CGPoint(x: h.maxX + gap, y: clampY(h.midY - card.height / 2))
        }
        if h.minX - gap - card.width - margin >= bounds.minX {
            return CGPoint(x: h.minX - gap - card.width, y: clampY(h.midY - card.height / 2))
        }
        if h.maxY + gap + card.height + margin <= bounds.maxY {
            return CGPoint(x: clampX(h.midX - card.width / 2), y: h.maxY + gap)
        }
        if h.minY - gap - card.height - margin >= bounds.minY + 40 {
            return CGPoint(x: clampX(h.midX - card.width / 2), y: h.minY - gap - card.height)
        }
        return CGPoint(x: clampX(h.maxX - card.width - margin * 1.5), y: clampY(h.maxY - card.height - margin * 1.5))
    }
}

private nonisolated struct SpotlightShape: Shape {
    var hole: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if hole.width > 0.5, hole.height > 0.5 {
            let radius = min(12, hole.height / 2)
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return path
    }
}

private struct SpotlightRing: View {
    let pulse: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                .shadow(color: Color.accentColor.opacity(0.6), radius: 8)
            if pulse {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .phaseAnimator([false, true]) { ring, expanded in
                        ring.scaleEffect(expanded ? 1.04 : 1).opacity(expanded ? 0 : 0.8)
                    } animation: { expanded in
                        expanded ? .easeOut(duration: 1.3) : .linear(duration: 0.01)
                    }
            }
        }
    }
}

private struct TourCard: View {
    let step: TourStep
    private let tour = Onboarding.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: step.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.gradient, in: .rect(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Step \(tour.index + 1) of \(tour.steps.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(step.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(step.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ProgressDots(count: tour.steps.count, current: tour.index)

            HStack(spacing: 8) {
                if !tour.isLast {
                    Button("Skip Tour") { tour.finish() }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                        .help("Close the tour (Esc). You can repeat it from Settings › General.")
                }
                Spacer(minLength: 8)
                if !tour.isFirst {
                    Button("Previous") { tour.previous() }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .help("Previous step (←)")
                }
                Button(tour.isLast ? "Get Started" : tour.isFirst ? "Start Tour" : "Next") { tour.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .help(tour.isLast ? "Finish the tour (Return)" : "Next step (Return or →)")
                // → also advances.
                Button("Next") { tour.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(Text(step.title))
        .id(step.id)
    }
}

private struct ProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.accentColor : Color.secondary.opacity(i < current ? 0.55 : 0.25))
                    .frame(width: i == current ? 18 : 6, height: 6)
            }
        }
        .animation(.smooth(duration: 0.3), value: current)
        .accessibilityHidden(true)
    }
}
