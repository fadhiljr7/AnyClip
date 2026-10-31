//
//  ClipEditorView.swift
//  AnyClip
//

import SwiftUI
import SwiftData

struct ClipEditorView: View {
    @Bindable var clip: Clip
    @State private var preview = PreviewController()
    @State private var showInspector = true
    @AppStorage(AppSettings.Key.inspectorTab) private var tab: InspectorTab = .captions
    @State private var showFraming = false
    @State private var transcript: Transcript?
    /// The clip's revision when the editor opened; its thumbnail only needs redoing if the picture changed.
    @State private var openedRevision = 0

    enum InspectorTab: String, CaseIterable, Identifiable {
        case captions, hook, broll, framing, details
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .captions: "Captions"
            case .hook: "Hook"
            case .broll: "B-roll"
            case .framing: "Framing"
            case .details: "Details"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                PreviewPlayerView(controller: preview)
                    .accessibilityLabel("Clip preview")
                    .accessibilityAction(named: "Play or Pause") { preview.togglePlay() }
                if let error = preview.error {
                    ContentUnavailableView {
                        Label("Can’t Preview This Clip", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { preview.retry(for: clip) }
                    }
                    .foregroundStyle(.white)
                    .background(.black)
                } else if preview.isLoading {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Preparing preview…")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .environment(\.colorScheme, .dark)
                }
            }
            .overlay(alignment: .bottom) {
                if preview.error == nil && !preview.isLoading { PreviewTransport(preview: preview).padding(.bottom, 16) }
            }
            .background(.black)
            .tourTarget(.editorPreview)
            .onTapGesture { preview.togglePlay() }

            TrimBar(clip: clip, sourceDuration: clip.project?.duration ?? clip.end,
                    words: transcript?.words(in: max(0, clip.start - 120)...(clip.end + 120)) ?? [],
                    playhead: { preview.sourceTime },
                    teaser: clip.activeTeaser,
                    onSeek: { preview.seek(toSource: $0) },
                    onCommit: commit)
                .tourTarget(.trimBar)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)
        }
        .navigationTitle(clip.title)
        .navigationSubtitle(clip.project?.title ?? "")
        .focusedSceneValue(\.selectedClip, clip)
        .focusedSceneValue(\.selectedProject, clip.project)
        .focusedSceneValue(\.editorActions, actions)
        .inspector(isPresented: $showInspector) {
            VStack(spacing: 0) {
                Picker("Inspector", selection: $tab) {
                    ForEach(InspectorTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(12)
                Divider()
                Group {
                    switch tab {
                    case .captions: CaptionInspector(clip: clip, transcript: transcript, onChange: commitOverlay,
                                                     onSeek: { preview.seek(toSource: $0) })
                    case .hook: HookInspector(clip: clip, transcript: transcript, preview: preview, onChange: commitOverlay)
                    case .broll: BRollInspector(clip: clip, transcript: transcript, playhead: { preview.sourceTime },
                                                onChange: commitOverlay, onSeek: { preview.seek(toSource: $0) })
                    case .framing: FramingInspector(clip: clip, showEditor: $showFraming, onChange: commit)
                    case .details: DetailsInspector(clip: clip, transcript: transcript)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(minWidth: 300, idealWidth: 330, maxWidth: .infinity)
            .tourTarget(.inspector)
            .inspectorColumnWidth(min: 300, ideal: 330, max: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(clip.isSaved ? "Remove from Saved" : "Add to Saved",
                       systemImage: clip.isSaved ? "bookmark.fill" : "bookmark") { clip.isSaved.toggle() }
                    .help(clip.isSaved ? "Remove from Saved (⌘D)" : "Add to Saved (⌘D)")
                if let url = clip.exportedURL {
                    ShareLink(item: url)
                        .help("Share the exported clip")
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .help("Show the exported clip in Finder")
                }
            }
            ToolbarItem {
                exportButton
            }
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                    .help("Show or hide the inspector")
            }
        }
        .sheet(isPresented: $showFraming, onDismiss: commit) {
            FramingEditor(clip: clip)
        }
        .background(PlaybackKeys(actions: actions))
        .onAppear {
            if let project = clip.project { transcript = Studio.shared.transcript(for: project) }
            openedRevision = clip.revision
            preview.update(for: clip)
        }
        .onDisappear {
            preview.teardown()
            if clip.revision != openedRevision { Studio.shared.refreshThumbnail(clip) }
        }
    }

    private var actions: EditorActions {
        EditorActions(
            togglePlay: { preview.togglePlay() },
            step: { preview.step($0) },
            setStartToPlayhead: {
                clip.start = ClipTrim.start(preview.sourceTime, end: clip.end)
                commit()
            },
            setEndToPlayhead: {
                clip.end = ClipTrim.end(preview.sourceTime, start: clip.start, sourceDuration: clip.project?.duration ?? clip.end)
                commit()
            })
    }

    @ViewBuilder
    private var exportButton: some View {
        if let p = Studio.shared.exporting[clip.id] {
            HStack(spacing: 8) {
                ProgressView(value: p).frame(width: 90)
                Text("Exporting…").font(.callout)
                Button("Cancel Export", systemImage: "xmark.circle.fill") { Studio.shared.cancelExport(clip) }
                    .labelStyle(.iconOnly)
                    .help("Cancel this export")
            }
        } else {
            Button {
                Studio.shared.export([clip])
            } label: {
                Label(clip.exportedURL == nil ? "Export" : "Export Again", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.glassProminent)
            .help("Render this clip to your export folder (⌘E)")
            .disabled(Studio.shared.isQueued(clip))
        }
    }

    private func commit() {
        clip.markChanged()
        preview.update(for: clip)
    }

    private func commitOverlay() {
        preview.update(for: clip)
    }
}

/// Play controls over the preview. Its own view, so the time readout updating during playback
/// doesn't re-evaluate the whole editor (and its inspector) many times a second.
struct PreviewTransport: View {
    let preview: PreviewController

    var body: some View {
        HStack(spacing: 6) {
            Button { preview.step(-5) } label: { Image(systemName: "gobackward.5").transportTarget() }
                .help("Back 5 seconds")
                .accessibilityLabel("Back 5 seconds")
            Button { preview.togglePlay() } label: {
                Image(systemName: preview.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .transportTarget()
            }
            .help(preview.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(preview.isPlaying ? "Pause" : "Play")
            Button { preview.step(5) } label: { Image(systemName: "goforward.5").transportTarget() }
                .help("Forward 5 seconds")
                .accessibilityLabel("Forward 5 seconds")
            Text("\(formatTimestamp(preview.currentTime)) / \(formatTimestamp(preview.duration))")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 86)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassEffect(.clear.interactive(), in: .capsule)
        .environment(\.colorScheme, .dark)
    }
}

/// The editor's plain-key shortcuts: Space plays, ← and → move a second, I and O set the clip's start and end.
/// They work wherever the window's focus is, except where the key has its own meaning: while typing or on a control.
private struct PlaybackKeys: NSViewRepresentable {
    let actions: EditorActions

    func makeNSView(context: Context) -> KeyView { KeyView() }

    func updateNSView(_ view: KeyView, context: Context) { view.actions = actions }

    final class KeyView: NSView {
        var actions: EditorActions?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !(window.firstResponder is NSText), !(window.firstResponder is NSControl), let actions else { return false }
            switch event.specialKey {
            case .leftArrow: actions.step(-1)
            case .rightArrow: actions.step(1)
            default:
                switch event.charactersIgnoringModifiers?.lowercased() {
                case " ": actions.togglePlay()
                case "i": actions.setStartToPlayhead()
                case "o": actions.setEndToPlayhead()
                default: return false
                }
            }
            return true
        }
    }
}

private extension View {
    /// The whole 28-point square clicks, not just the symbol's own small outline.
    func transportTarget() -> some View {
        frame(width: 28, height: 28).contentShape(.rect)
    }
}

// MARK: - Shared inspector bits

/// Bridges a hex string to a SwiftUI Color for ColorPicker.
func hexColor(_ hex: Binding<String>) -> Binding<Color> {
    Binding<Color>(
        get: { Color(cgColor: TextRenderer.color(hex.wrappedValue)) },
        set: { newValue in
            guard let c = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            hex.wrappedValue = TextRenderer.hex(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent)
        })
}

enum FontCatalog {
    static let families: [String] = {
        let preferred = ["Avenir Next", "Futura", "Helvetica Neue", "Impact", "Arial Black", "Gill Sans", "Montserrat",
                         "Poppins", "Bebas Neue", "Anton", "SF Pro", "Menlo", "Marker Felt", "Chalkboard SE", "Georgia"]
        let all = Set(NSFontManager.shared.availableFontFamilies)
        let top = preferred.filter { all.contains($0) }
        return top + all.subtracting(top).sorted()
    }()
}

struct CaptionInspector: View {
    @Bindable var clip: Clip
    let transcript: Transcript?
    var onChange: () -> Void
    var onSeek: (Double) -> Void
    @State private var style = CaptionStyle()

    var body: some View {
        Form {
            Section {
                Toggle("Show captions", isOn: $style.enabled)
                CaptionPresetPicker(selection: Binding(get: { style.presetID }, set: { id in
                    var preset = CaptionPreset.preset(id).style
                    preset.positionY = style.positionY
                    preset.enabled = style.enabled
                    style = preset
                }), wraps: true)
                .padding(.vertical, 4)
            }
            Section("Text") {
                Picker("Font", selection: $style.fontName) {
                    ForEach(FontCatalog.families, id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Size") { Slider(value: $style.size, in: 0.035...0.13) }
                LabeledContent("Words at a time") {
                    CountStepper(value: $style.wordsPerChunk, range: 1...8, label: "Words at a time")
                }
                Toggle("All caps", isOn: $style.uppercase)
                LabeledContent("Position") { Slider(value: $style.positionY, in: 0.12...0.92) }
            }
            Section("Look") {
                Picker("Highlight", selection: $style.highlight) {
                    Text("Word color").tag(CaptionHighlight.color)
                    Text("Word box").tag(CaptionHighlight.box)
                    Text("Karaoke").tag(CaptionHighlight.karaoke)
                    Text("None").tag(CaptionHighlight.none)
                }
                Picker("Animation", selection: $style.entrance) {
                    Text("Pop").tag(CaptionAnimation.pop)
                    Text("Rise").tag(CaptionAnimation.rise)
                    Text("Fade").tag(CaptionAnimation.fade)
                    Text("None").tag(CaptionAnimation.none)
                }
                ColorPicker("Text", selection: hexColor($style.textColor), supportsOpacity: false)
                ColorPicker("Highlight", selection: hexColor($style.highlightColor), supportsOpacity: false)
                ColorPicker("Outline", selection: hexColor($style.strokeColor), supportsOpacity: false)
                LabeledContent("Outline width") { Slider(value: $style.strokeWidth, in: 0...0.2) }
                Toggle("Shadow", isOn: $style.shadow)
                Toggle("Glow", isOn: $style.glow)
            }
            Section("Edit Words") {
                let chunks = CaptionTimeline.chunks(clip.captionWords(transcript: transcript), perChunk: style.wordsPerChunk)
                if chunks.isEmpty {
                    Text("No speech in this clip.").foregroundStyle(.secondary)
                }
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                    ChunkRow(chunk: chunk, onSeek: onSeek) { text in
                        clip.replaceCaption(chunk, with: text, transcript: transcript)
                        onChange()
                    }
                }
                if clip.editedWords != nil {
                    Button("Restore Original Words") {
                        clip.editedWords = nil
                        onChange()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { style = clip.captionStyle }
        .onChange(of: clip.id) { style = clip.captionStyle }
        .onChange(of: style) {
            // Loading the clip's style into the form is not an edit.
            guard style != clip.captionStyle else { return }
            clip.captionStyle = style
            onChange()
        }
    }
}

struct ChunkRow: View {
    let chunk: [Word]
    var onSeek: (Double) -> Void
    var onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button(formatTimestamp(chunk.first?.start ?? 0)) { onSeek(chunk.first?.start ?? 0) }
                .buttonStyle(.borderless)
                .font(.caption.monospacedDigit())
                .help("Jump to this line")
            TextField("Caption", text: $text)
                .labelsHidden()
                .focused($focused)
                .onSubmit { commitIfChanged() }
                .onChange(of: focused) { if !focused { commitIfChanged() } }
        }
        .onAppear { text = original }
        .onChange(of: original) { text = original }
    }

    private var original: String { chunk.map(\.text).joined(separator: " ") }

    private func commitIfChanged() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != original, !trimmed.isEmpty { onCommit(trimmed) }
    }
}

struct HookInspector: View {
    @Bindable var clip: Clip
    let transcript: Transcript?
    let preview: PreviewController
    var onChange: () -> Void
    @State private var style = HookStyle()
    @State private var text = ""
    @State private var ideas: [String] = []
    @State private var ideasSource = ""
    @State private var writing = false
    @State private var hookError: String?
    /// Changed to bring the hook title section into view.
    @State private var showHook = 0

    var body: some View {
        let teaser = Studio.shared.teaserText(for: clip)
        ScrollViewReader { proxy in
        Form {
            TeaserSection(clip: clip, transcript: transcript, preview: preview, onChosen: checkHookAgainstTeaser,
                          onShowHook: { showHook += 1 })
            Section {
                Toggle("Show hook title", isOn: $style.enabled)
                TextField("Hook", text: $text, prompt: Text("A line that makes people stay"), axis: .vertical)
                    .lineLimit(2...4)
                    .onSubmit { commitText() }
                    .onChange(of: text) { commitText() }
                if style.enabled, let teaser, TeaserText.repeats(text, teaser) {
                    WarningLabel("This hook says the same thing as the teaser. A hook that adds context or asks a question works better.")
                }
                Button(action: suggestHooks) {
                    HStack {
                        Label("Suggest Hooks", systemImage: "sparkles")
                        if writing { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(writing)
                .help(teaser != nil ? "Writes hooks that add to the teaser instead of repeating it."
                                    : "Writes new hooks from what the speaker says in this clip.")
                if let hookError {
                    WarningLabel(verbatim: hookError)
                }
                ForEach(ideas, id: \.self) { idea in
                    HStack(alignment: .firstTextBaseline) {
                        Text(idea).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Use") {
                            text = idea
                            commitText()
                            ideas = []
                        }
                    }
                }
                if !ideas.isEmpty {
                    Text("Suggested by \(ideasSource)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Shown at the top of the clip in the first seconds — the line that stops the scroll.")
                    .foregroundStyle(.secondary)
            }
            .id("hookTitle")
            Section("Timing") {
                Toggle("Keep for the whole clip", isOn: Binding(get: { style.duration == 0 },
                                                                 set: { style.duration = $0 ? 0 : 4 }))
                if style.duration > 0 {
                    LabeledContent("Show for", value: "\(Int(style.duration)) s")
                    Slider(value: $style.duration, in: 1...15, step: 1)
                }
            }
            lookSection
            textSection
        }
        .formStyle(.grouped)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugDriver.suggestHooks)) { _ in suggestHooks() }
        .onReceive(NotificationCenter.default.publisher(for: DebugDriver.teaserChosen)) { _ in checkHookAgainstTeaser() }
        .onReceive(NotificationCenter.default.publisher(for: DebugDriver.hookLook)) { note in
            let value = note.object as? String
            if let look = value.flatMap(HookLook.init(rawValue:)) { style.look = look }
            if value == "on" || value == "off" { style.enabled = value == "on" }
        }
        .onChange(of: ideas) { Studio.shared.debugLog("hook ideas shown: \(ideas.joined(separator: " | "))") }
        .onChange(of: hookError) { if let hookError { Studio.shared.debugLog("hook error: \(hookError)") } }
        #endif
        .onChange(of: showHook) { withAnimation { proxy.scrollTo("hookTitle", anchor: .top) } }
        }
        .onAppear { style = clip.hookStyle; text = clip.hook }
        .onChange(of: style) {
            // Loading the clip's style into the form is not an edit.
            guard style != clip.hookStyle else { return }
            clip.hookStyle = style
            onChange()
        }
    }

    private var lookSection: some View {
        Section {
            Picker("Style", selection: $style.look) {
                ForEach(HookLook.allCases) { Text($0.name).tag($0) }
            }
            // Only the settings this look uses.
            switch style.look {
            case .card:
                ColorPicker("Text", selection: hexColor($style.textColor), supportsOpacity: false)
                ColorPicker("Card", selection: hexColor($style.boxColor), supportsOpacity: false)
                LabeledContent("Corners") { Slider(value: $style.cornerRadius, in: 0...0.9) }
            case .strip:
                ColorPicker("Text", selection: hexColor($style.stripTextColor), supportsOpacity: false)
                ColorPicker("Strip", selection: hexColor($style.stripColor), supportsOpacity: false)
                Toggle("Tilt", isOn: $style.stripTilt)
            case .sideAccent:
                ColorPicker("Text", selection: hexColor($style.accentTextColor), supportsOpacity: false)
                ColorPicker("Accent", selection: hexColor($style.accentColor), supportsOpacity: false)
                Toggle("Dark backdrop", isOn: $style.accentBackdrop)
            case .outline:
                ColorPicker("Text", selection: hexColor($style.outlineTextColor), supportsOpacity: false)
                ColorPicker("Outline", selection: hexColor($style.outlineColor), supportsOpacity: false)
                LabeledContent("Thickness") { Slider(value: $style.outlineWidth, in: 0...0.25) }
            }
        } header: {
            Text("Look")
        } footer: {
            Text(style.look.summary)
                .foregroundStyle(.secondary)
        }
    }

    private var textSection: some View {
        Section("Text") {
            Picker("Font", selection: $style.fontName) {
                ForEach(FontCatalog.families, id: \.self) { Text($0).tag($0) }
            }
            LabeledContent("Size") { Slider(value: $style.size, in: 0.035...0.09) }
            LabeledContent("Position") { Slider(value: $style.positionY, in: 0...1) }
            Toggle("All caps", isOn: $style.uppercase)
        }
    }

    private func commitText() {
        guard text != clip.hook else { return }
        clip.hook = text
        onChange()
    }

    private func suggestHooks() {
        writing = true
        hookError = nil
        Task {
            do {
                let result = try await Studio.shared.suggestHooks(for: clip)
                ideas = result.hooks
                ideasSource = result.source
            } catch {
                hookError = error.localizedDescription
            }
            writing = false
        }
    }

    /// After a teaser is picked, offers new hooks if the current one just repeats it. Nothing changes until one is used.
    private func checkHookAgainstTeaser() {
        guard style.enabled, !writing, let teaser = Studio.shared.teaserText(for: clip), TeaserText.repeats(clip.hook, teaser) else { return }
        suggestHooks()
        showHook += 1
    }
}

struct FramingInspector: View {
    @Bindable var clip: Clip
    @Binding var showEditor: Bool
    var onChange: () -> Void
    @State private var tracking = false

    var body: some View {
        Form {
            Section("Format") {
                Picker("Format", selection: Binding(get: { clip.aspect }, set: {
                    clip.aspect = $0
                    // Stacking only works in 9:16; turning it off also puts the captions back.
                    if $0 != .vertical { clip.setStacked(false) }
                    onChange()
                })) {
                    ForEach(AspectRatio.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            layoutSection
            Section {
                LabeledContent("Keyframes", value: "\(clip.keyframes.count)")
                Button("Adjust Framing…") { showEditor = true }
                Button {
                    retrack()
                } label: {
                    HStack {
                        Text("Follow Faces Again")
                        if tracking { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(tracking)
                Button("Center Frame") {
                    let zoom = clip.keyframes.first?.zoom ?? 1
                    clip.keyframes = [FrameKeyframe(time: clip.start, cx: 0.5, cy: 0.5, zoom: zoom)]
                    onChange()
                }
                LabeledContent("Zoom") {
                    Slider(value: Binding(get: { clip.keyframes.first?.zoom ?? 1 }, set: { z in
                        var kfs = clip.keyframes
                        if kfs.isEmpty { kfs = [.centered(at: clip.start)] }
                        for i in kfs.indices { kfs[i].zoom = z }
                        clip.keyframes = kfs
                    }), in: 1...2.5) { editing in
                        if !editing { onChange() }
                    }
                }
            } header: {
                Text("Camera")
            } footer: {
                Text(clip.stackPlan != nil
                     ? "In the stacked parts, each speaker is framed automatically. Adjust Framing changes the full-frame parts."
                     : "AnyClip follows the main speaker automatically. Adjust Framing lets you place the crop yourself at any moment.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Shown only where it helps: a switch for clips with two speakers on screen, and a short reason when the
    /// project asked for stacking but this clip can't use it. Solo clips in ordinary projects show nothing.
    @ViewBuilder
    private var layoutSection: some View {
        if let verdict = clip.twoSpeaker {
            if verdict.allowsStacking {
                Section {
                    StackedLayoutToggle(isOn: Binding(get: { clip.stackedLayout }, set: { clip.setStacked($0); onChange() })) {
                        Text("Two-Speaker Stacked Layout")
                    }
                    .disabled(clip.aspect != .vertical)
                    if clip.stackedLayout && clip.aspect == .vertical {
                        Toggle("Swap Speakers", isOn: Binding(get: { clip.stackSwapped }, set: { clip.stackSwapped = $0; onChange() }))
                            .help("Shows the speaker on the right of the video in the top panel.")
                    }
                } header: {
                    Text("Layout")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        switch verdict {
                        case .mixed(let share):
                            Text("Both speakers appear to be on screen in \(Int((share * 100).rounded()))% of this clip. When only one is visible, the layout switches to full frame.")
                        default:
                            Text("Both speakers appear to be on screen throughout this clip.")
                        }
                        if clip.aspect != .vertical {
                            Text("The stacked layout is available in the 9:16 format.")
                        } else if clip.stackedLayout && clip.shotsOutsideTrim {
                            Text("Part of the trimmed clip hasn’t been checked and is shown full-frame. Click Follow Faces Again to check it.")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            } else if clip.project?.options.stacked == true {
                Section("Layout") {
                    Text(verdict == .oneSpeaker
                         ? "Only one speaker is on screen at a time in this clip, so it uses the full-frame layout."
                         : "AnyClip couldn’t see two speakers clearly enough in this clip — faces may be too small, turned away or covered by graphics — so it uses the full-frame layout.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func retrack() {
        guard let video = clip.project?.videoURL else { return }
        tracking = true
        let range = clip.start...clip.end, aspect = clip.aspect
        Task {
            let faces = await FaceTracker.analyze(video: video, range: range, aspect: aspect)
            tracking = false
            guard clip.modelContext != nil else { return }
            clip.keyframes = faces.keyframes
            if let shots = faces.shots { clip.shots = shots }
            // A clip that turns out to have only one speaker on screen can't stay stacked.
            if clip.twoSpeaker?.allowsStacking != true { clip.setStacked(false) }
            onChange()
        }
    }
}

struct DetailsInspector: View {
    @Bindable var clip: Clip
    let transcript: Transcript?

    var body: some View {
        Form {
            Section("Post") {
                TextField("Title", text: $clip.title, axis: .vertical)
                    .lineLimit(1...3)
                TextField("Caption", text: $clip.summary, prompt: Text("A short teaser for the post"), axis: .vertical)
                    .lineLimit(2...6)
                Picker("Category", selection: Binding(get: { clip.category }, set: { clip.category = $0 })) {
                    ForEach(ClipCategory.allCases, id: \.self) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                Button("Copy Title and Caption") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString([clip.title, clip.summary].filter { !$0.isEmpty }.joined(separator: "\n\n"), forType: .string)
                }
            }
            Section("Score") {
                LabeledContent("Virality score") {
                    ScoreBadge(score: clip.score)
                }
                Text("An estimate of how well the opening hooks, how complete the story is and how shareable it is. Treat it as a hint, not a promise.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Transcript") {
                Text(clip.captionWords(transcript: transcript).map(\.text).joined(separator: " "))
                    .textSelection(.enabled)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - B-roll

struct BRollInspector: View {
    @Bindable var clip: Clip
    let transcript: Transcript?
    /// Playhead in source time; read only when a card is added.
    let playhead: () -> Double
    var onChange: () -> Void
    var onSeek: (Double) -> Void

    private var inserts: [BRollInsert] { clip.broll }

    var body: some View {
        Form {
            Section {
                Toggle("Show B-roll", isOn: Binding(get: { clip.brollEnabled }, set: { clip.brollEnabled = $0; onChange() }))
            } footer: {
                Text("Animated keyword cards cut into the clip. Turn this off to leave them out of the preview and export.")
                    .foregroundStyle(.secondary)
            }
            if clip.brollEnabled {
                Section("Cards") {
                    if inserts.isEmpty {
                        Text("This clip has no B-roll yet. Add a card at the playhead or let AnyClip suggest some.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(inserts) { insert in
                        BRollRow(insert: binding(for: insert.id), clipStart: clip.start, clipEnd: clip.end,
                                 onSeek: onSeek, onDelete: { remove(insert.id) })
                    }
                }
                Section {
                    Button("Add Card at Playhead", systemImage: "plus.rectangle.on.rectangle") { add() }
                    Button("Suggest Cards Again", systemImage: "sparkles") { suggest() }
                        .help("Replaces the cards with new suggestions from the transcript.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for id: UUID) -> Binding<BRollInsert> {
        Binding(
            get: { clip.broll.first { $0.id == id } ?? BRollInsert(time: 0, duration: 0, keyword: "", style: .note) },
            set: { newValue in
                var all = clip.broll
                if let i = all.firstIndex(where: { $0.id == id }) { all[i] = newValue }
                clip.broll = all
                onChange()
            })
    }

    private func remove(_ id: UUID) {
        clip.broll.removeAll { $0.id == id }
        onChange()
    }

    private func words() -> [Word] {
        clip.captionWords(transcript: transcript)
    }

    private func add() {
        let insert = BRollPlanner.insert(at: playhead(), words: words(), context: Studio.shared.brollContext(for: clip))
        clip.broll.append(insert)
        onSeek(insert.time)
        onChange()
    }

    private func suggest() {
        clip.broll = BRollPlanner.plan(words: words(), context: Studio.shared.brollContext(for: clip))
        onChange()
    }
}

struct BRollRow: View {
    @Binding var insert: BRollInsert
    let clipStart: Double
    let clipEnd: Double
    var onSeek: (Double) -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    onSeek(insert.time)
                } label: {
                    Label(formatTimestamp(max(0, insert.time - clipStart)), systemImage: "play.circle")
                        .monospacedDigit()
                }
                .buttonStyle(.borderless)
                .help("Jump to this card")
                Spacer()
                Picker("Style", selection: Binding(get: { insert.style }, set: { style in
                    insert.style = style
                    insert.duration = style.kind == .full ? BRollInsert.fullDuration : BRollInsert.overlayDuration
                })) {
                    Section("Full Screen") {
                        ForEach(BRollStyle.fullStyles) { Text($0.name).tag($0) }
                    }
                    Section("Over the Video") {
                        ForEach(BRollStyle.overlayStyles) { Text($0.name).tag($0) }
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button("Delete Card", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Delete this card")
            }
            CommitTextField(title: "Word", prompt: "Big word on the card", text: $insert.keyword)
            CommitTextField(title: "Small text", prompt: "Optional, shown above", text: $insert.lead)
            HStack {
                Stepper(value: Binding(get: { insert.duration }, set: { insert.duration = min($0, max(1, clipEnd - insert.time)) }),
                        in: 1...6, step: 0.2) {
                    Text("Length \(insert.duration, format: .number.precision(.fractionLength(1))) s")
                        .monospacedDigit()
                }
                Spacer()
                HStack(spacing: 5) {
                    ForEach(BRollPalette.all.indices, id: \.self) { i in
                        Button {
                            insert.palette = i
                        } label: {
                            Circle()
                                .fill(Color(cgColor: TextRenderer.color(BRollPalette.all[i].background)))
                                .overlay(Circle().fill(Color(cgColor: TextRenderer.color(BRollPalette.all[i].accent))).padding(5))
                                .overlay(Circle().strokeBorder(insert.palette == i ? Color.accentColor : .clear, lineWidth: 2))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Color \(i + 1)")
                        .accessibilityAddTraits(insert.palette == i ? .isSelected : [])
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A text field that only saves when you press Return or leave it, so the preview isn't redrawn on every keystroke.
struct CommitTextField: View {
    let title: LocalizedStringKey
    var prompt: LocalizedStringKey?
    @Binding var text: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft, prompt: prompt.map { Text($0) })
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
            .onAppear { draft = text }
            .onChange(of: text) { if !focused { draft = text } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != text { text = trimmed }
    }
}
