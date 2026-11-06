//
//  NewProjectView.swift
//  AnyClip
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct NewProjectView: View {
    @Environment(\.modelContext) private var context
    @Bindable private var state = AppState.shared
    @AppStorage(AppSettings.Key.lastOptions) private var lastOptionsData = Data()
    @AppStorage(AppSettings.Key.aiProvider) private var providerRaw = AIProvider.apple.rawValue

    @State private var link = ""
    @State private var file: URL?
    @State private var subtitleFile: URL?
    @State private var options = ProjectOptions()
    private let presets = HookPresetLibrary.shared
    @State private var isTargeted = false
    @State private var showSubtitleImporter = false
    @FocusState private var linkFocused: Bool

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .apple }

    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var linkIsValid: Bool {
        guard let url = URL(string: trimmedLink), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
    /// The export folder as people know it, e.g. ~/Movies/AnyClip.
    private var exportFolderName: String {
        let path = AppPaths.exportFolder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private var canCreate: Bool {
        (file != nil || linkIsValid) && (options.transcription != .subtitleFile || subtitleFile != nil)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Turn a long video into short clips")
                        .font(.title2.weight(.semibold))
                    Text("Paste a link or drop a video. AnyClip transcribes it on this Mac, picks the strongest moments and frames them for vertical video.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section("Video") {
                if let file {
                    LabeledContent {
                        Button("Remove", systemImage: "xmark.circle.fill") { self.file = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Remove video")
                    } label: {
                        Label(file.lastPathComponent, systemImage: "film")
                    }
                } else {
                    TextField("Link", text: $link, prompt: Text("YouTube, TikTok, Instagram, X or any video link"))
                        .focused($linkFocused)
                        .onSubmit(create)
                    if !trimmedLink.isEmpty && !linkIsValid {
                        WarningLabel("Enter a full link that starts with https://")
                    }
                    LabeledContent("Or use a file on this Mac") {
                        Button("Choose Video…") { state.showFileImporter = true }
                    }
                }
                Picker("Transcript", selection: $options.transcription) {
                    ForEach(TranscriptionMethod.allCases) { method in
                        Label {
                            Text(method.title)
                            Text(method.summary)
                        } icon: {
                            Image(systemName: method.symbol)
                        }
                        .tag(method)
                    }
                }
                TranscriptMethodDetail(method: options.transcription,
                                       link: file == nil ? trimmedLink : nil,
                                       language: options.language,
                                       transcriptLanguage: $options.transcriptLanguage,
                                       subtitleFile: $subtitleFile,
                                       showSubtitleImporter: $showSubtitleImporter)
            }
            .tourTarget(.videoSource)

            Section("Clips") {
                LabeledContent("Number of clips") {
                    CountStepper(value: $options.clipCount, range: 1...20, label: "Number of clips")
                }
                Picker("Length", selection: $options.length) {
                    Text("Auto").tag(ClipLength.auto)
                    Text("15–30 s").tag(ClipLength.short)
                    Text("30–60 s").tag(ClipLength.medium)
                    Text("60–90 s").tag(ClipLength.long)
                }
                Picker("Format", selection: $options.aspect) {
                    ForEach(AspectRatio.allCases) { aspect in
                        Text(aspect.rawValue).tag(aspect)
                    }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $options.faceTracking) {
                    Text("Keep faces in frame")
                    Text("Finds the speaker’s face and moves the crop with them, so they stay in the picture when a wide video is cropped to the clip format.")
                }
                StackedLayoutToggle(isOn: $options.stacked) {
                    Text("Two-Speaker Stacked Layout")
                    Text(options.aspect == .vertical
                         ? "For podcasts and interviews: shows both speakers one above the other whenever they’re on screen together."
                         : "Available in the 9:16 format.")
                }
                .disabled(options.aspect != .vertical)
                Picker("Spoken language", selection: $options.language) {
                    Text("Detect Automatically").tag("auto")
                    Divider()
                    ForEach(LanguageList.codes, id: \.self) { code in
                        Text(LanguageList.name(code)).tag(code)
                    }
                }
                TextField("Focus", text: $options.topic, prompt: Text("Optional, e.g. “money advice” or “funny moments”"))
            }
            .tourTarget(.clipOptions)

            Section("Style") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Captions") {
                        CaptionPresetPicker(selection: $options.captionPresetID)
                    }
                    Text("This is the starting style. You can change the captions of each clip in the editor’s Captions tab.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $options.hookEnabled) {
                    Text("Hook title at the start")
                    Text("Shows a short, attention-grabbing title over the first seconds of each clip. You can edit or turn it off in the editor.")
                }
                if options.hookEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Hook style") {
                            HookPresetPicker(selection: $options.hookPresetID)
                        }
                        Text(presets.saved.isEmpty
                             ? "To add your own, style a hook in the editor’s Hook tab and choose Save as Preset."
                             : "Your saved presets keep their timing, look and text settings.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $options.broll) {
                    Text("B-roll")
                    Text("Adds 1–3 animated keyword cards to each clip. You can edit or remove them in the editor.")
                }
                Toggle(isOn: $options.exportWhenDone) {
                    Text("Export clips when finished")
                    Text("Renders every clip as a video file into \(exportFolderName) as soon as the project is ready, so you don’t have to export them one by one.")
                }
            }
            .tourTarget(.styleOptions)

            Section {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: provider == .apple ? "apple.intelligence" : "sparkles")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Moments and titles are suggested by \(provider.displayName).")
                        Text(provider == .apple
                             ? "Your transcript stays on this Mac. If Apple Intelligence is off, AnyClip uses built-in scoring."
                             : "Your transcript is sent to \(provider.recipient) with your own API key.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    SettingsLink { Text("Change…") }
                }
                .tourTarget(.aiProvider)
            } footer: {
                HStack {
                    Spacer()
                    Button(action: create) {
                        Text("Create Clips")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canCreate)
                    .tourTarget(.createButton)
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .navigationTitle("New Project")
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 14))
                    .overlay { Label("Drop to use this video", systemImage: "arrow.down.doc").font(.title3) }
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            if url.isFileURL {
                guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true else { return false }
                file = url
            } else {
                file = nil
                link = url.absoluteString
            }
            return true
        } isTargeted: { isTargeted = $0 }
        .fileImporter(isPresented: $state.showFileImporter, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result { file = url }
        }
        .fileImporter(isPresented: $showSubtitleImporter, allowedContentTypes: [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText, .plainText]) { result in
            if case .success(let url) = result { subtitleFile = url }
        }
        .onAppear {
            if let saved = try? JSONDecoder().decode(ProjectOptions.self, from: lastOptionsData) {
                options = saved
                options.topic = ""
                options.transcriptLanguage = nil
            }
            // The preset used last time may have been deleted since.
            if presets.preset(id: options.hookPresetID) == nil { options.hookPresetID = HookPreset.defaultID }
            fillLinkFromClipboard()
            linkFocused = file == nil && !Onboarding.shared.isActive
        }
    }

    /// Offers a copied video link, once per thing copied, and only where reading the clipboard won't prompt.
    private func fillLinkFromClipboard() {
        let clipboard = NSPasteboard.general
        guard file == nil, link.isEmpty, clipboard.changeCount != state.lastClipboardChange,
              clipboard.accessBehavior == .default || clipboard.accessBehavior == .alwaysAllow else { return }
        state.lastClipboardChange = clipboard.changeCount
        if let pasted = clipboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           URL(string: pasted)?.scheme?.hasPrefix("http") == true, LanguageList.looksLikeVideoLink(pasted) {
            link = pasted
        }
    }

    private func create() {
        guard canCreate else { return }
        lastOptionsData = (try? JSONEncoder().encode(options)) ?? Data()
        let source: ProjectSource = file.map { .file($0) } ?? .url(trimmedLink)
        let project = Studio.shared.start(source, options: options,
                                          subtitleFile: options.transcription == .subtitleFile ? subtitleFile : nil, in: context)
        link = ""
        file = nil
        subtitleFile = nil
        state.selection = .project(project.id)
    }
}

/// The description of the chosen transcription method, plus what that method needs.
struct TranscriptMethodDetail: View {
    let method: TranscriptionMethod
    /// The pasted link, or nil when a file on this Mac is used.
    let link: String?
    let language: String
    @Binding var transcriptLanguage: String?
    @Binding var subtitleFile: URL?
    @Binding var showSubtitleImporter: Bool

    var body: some View {
        Text(method.summary)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        switch method {
        case .apple:
            EmptyView()
        case .youtube:
            YouTubeTranscriptStatus(link: link, language: language, selection: $transcriptLanguage)
        case .subtitleFile:
            LabeledContent("Subtitle file") {
                HStack {
                    if let subtitleFile {
                        Text(subtitleFile.lastPathComponent).foregroundStyle(.secondary)
                        Button("Remove", systemImage: "xmark.circle.fill") { self.subtitleFile = nil }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    Button(subtitleFile == nil ? "Attach SRT or VTT…" : "Change…") { showSubtitleImporter = true }
                }
            }
            if subtitleFile == nil {
                StatusLine("Attach a subtitle file to create clips with this option.", symbol: "exclamationmark.circle", tint: .orange)
            }
        case .whisper:
            WhisperModelRow()
        }
    }
}

/// Something that needs attention. The icon carries the color; orange text is too faint to read at this size.
struct WarningLabel: View {
    let text: Text

    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(verbatim: String) { text = Text(verbatim) }

    var body: some View {
        Label {
            text.foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.callout)
    }
}

/// A small status message with an icon.
struct StatusLine: View {
    let text: Text
    let symbol: String
    let tint: Color

    init(_ key: LocalizedStringKey, symbol: String, tint: Color) {
        self.text = Text(key)
        self.symbol = symbol
        self.tint = tint
    }

    init(verbatim: String, symbol: String, tint: Color) {
        self.text = Text(verbatim)
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Label {
            text.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
    }
}

/// Checks whether a YouTube link has a transcript as soon as it's pasted, and lets people pick
/// which one to use when there are several.
struct YouTubeTranscriptStatus: View {
    let link: String?
    let language: String
    @Binding var selection: String?
    @State private var state: CheckState = .idle

    enum CheckState: Equatable {
        case idle, checking
        case available(tracks: [CaptionTrack], suggested: String)
        case unavailable
        case failed(String)
    }

    private var isYouTube: Bool { link.map(Downloader.isYouTube) ?? false }

    var body: some View {
        Group {
            if link == nil {
                StatusLine("YouTube Transcript needs a YouTube link. For a file on this Mac, AnyClip uses Apple speech recognition instead.",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            } else if link?.isEmpty != false {
                StatusLine("Paste a YouTube link and AnyClip checks whether it has a transcript.", symbol: "info.circle", tint: .secondary)
            } else if !isYouTube {
                StatusLine("This isn’t a YouTube link, so AnyClip will use Apple speech recognition instead.",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            } else {
                switch state {
                case .idle, .checking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking for a transcript…").font(.callout).foregroundStyle(.secondary)
                    }
                case .available(let tracks, let suggested):
                    if tracks.count == 1, let track = tracks.first {
                        StatusLine(track.automatic
                                   ? "Transcript available in \(LanguageList.name(track.language)), generated by YouTube."
                                   : "Transcript available in \(LanguageList.name(track.language)), added by the creator.",
                                   symbol: "checkmark.circle.fill", tint: .green)
                    } else {
                        Picker("Transcript language", selection: Binding(
                            get: { selection.flatMap { key in tracks.contains { $0.key == key } ? key : nil } ?? suggested },
                            set: { selection = $0 })) {
                            ForEach(tracks, id: \.key) { track in
                                Text(track.automatic
                                     ? "\(LanguageList.name(track.language)) — generated by YouTube"
                                     : "\(LanguageList.name(track.language)) — added by the creator")
                                    .tag(track.key)
                            }
                        }
                        StatusLine("This video has \(tracks.count) transcripts. Choose the language that’s spoken in the video — the others are usually translations, so captions wouldn’t match what’s said.",
                                   symbol: "checkmark.circle.fill", tint: .green)
                    }
                case .unavailable:
                    StatusLine("This video has no YouTube transcript. AnyClip will use Apple speech recognition instead, or choose WhisperKit.",
                               symbol: "xmark.circle.fill", tint: .orange)
                case .failed(let reason):
                    StatusLine(verbatim: String(localized: "Couldn’t check for a transcript: \(reason)"),
                               symbol: "exclamationmark.triangle.fill", tint: .orange)
                }
            }
        }
        .task(id: isYouTube ? "\(link ?? "")|\(language)" : nil) { await check() }
    }

    private func check() async {
        guard let link, isYouTube else { state = .idle; return }
        state = .checking
        selection = nil
        // Wait for typing to settle before asking YouTube.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        guard ToolPaths.locate(.ytDlp) != nil else {
            state = .failed(String(localized: "yt-dlp isn’t installed yet. It’s installed automatically when you create the project."))
            return
        }
        do {
            let info = try await Downloader.fetchInfo(url: link)
            guard !Task.isCancelled else { return }
            let tracks = Downloader.captionTracks(in: info)
            if let suggested = Downloader.captionTrack(in: info, language: language == "auto" ? nil : language) {
                state = .available(tracks: tracks, suggested: suggested.key)
                // Remember the suggestion so the project uses exactly what's shown.
                selection = suggested.key
            } else {
                state = .unavailable
            }
        } catch {
            if !Task.isCancelled { state = .failed(error.localizedDescription) }
        }
    }
}

/// Model choice and one-time download for WhisperKit.
struct WhisperModelRow: View {
    @AppStorage(WhisperModel.defaultsKey) private var modelRaw = WhisperModel.recommended.rawValue
    private let models = WhisperModels.shared

    private var model: WhisperModel { WhisperModel(rawValue: modelRaw) ?? .recommended }

    var body: some View {
        Picker("Model", selection: $modelRaw) {
            ForEach(WhisperModel.allCases) { m in
                Text(m == .recommended ? "\(m.name) · \(m.sizeText) (Recommended)" : "\(m.name) · \(m.sizeText)").tag(m.rawValue)
            }
        }
        WhisperModelStatus(model: model)
    }
}

/// Installed, downloading or not-yet-downloaded state for one model, with the matching action.
struct WhisperModelStatus: View {
    let model: WhisperModel
    var showsDelete = false
    private let models = WhisperModels.shared

    var body: some View {
        HStack(spacing: 8) {
            switch models.activity[model] {
            case .downloading(let p):
                ProgressView(value: p).frame(maxWidth: 160)
                Text("Downloading… \(Int(p * 100))%").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Cancel") { models.cancel(model) }
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Preparing the model for this Mac (first time only)…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            case nil:
                if models.isInstalled(model) {
                    StatusLine("Downloaded. Works offline.", symbol: "checkmark.circle.fill", tint: .green)
                    Spacer()
                    if showsDelete {
                        Button("Delete", role: .destructive) { models.delete(model) }
                    }
                } else {
                    StatusLine("Needs a one-time download of \(model.sizeText). After that it works offline.",
                               symbol: "arrow.down.circle", tint: .accentColor)
                    Spacer()
                    Button("Download") { Task { try? await models.install(model) } }
                }
            }
        }
        if let error = models.errors[model] {
            StatusLine(verbatim: error, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }
}

struct CaptionPresetPicker: View {
    @Binding var selection: String
    /// Wraps onto more rows, for narrow places like the editor's inspector. Otherwise one row.
    var wraps = false

    var body: some View {
        if wraps {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74, maximum: 74), spacing: 8)], alignment: .leading, spacing: 8) {
                swatches
            }
        } else {
            HStack(spacing: 8) { swatches }
        }
    }

    private var swatches: some View {
        ForEach(CaptionPreset.all) { preset in
            Button {
                selection = preset.id
            } label: {
                VStack(spacing: 4) {
                    CaptionSwatch(style: preset.style)
                        .frame(width: 74, height: 46)
                        .clipShape(.rect(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(selection == preset.id ? Color.accentColor : .clear, lineWidth: 2.5)
                        }
                    Text(preset.name)
                        .font(.caption)
                        .foregroundStyle(selection == preset.id ? .primary : .secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(preset.name)
            .accessibilityAddTraits(selection == preset.id ? .isSelected : [])
        }
    }
}

/// The built-in hook looks and the saved presets, drawn like the caption swatches beside them.
/// One row while they fit, wrapping onto more rows once there are many saved presets.
struct HookPresetPicker: View {
    @Binding var selection: String
    private let library = HookPresetLibrary.shared

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { swatches }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74, maximum: 74), spacing: 8)], alignment: .trailing, spacing: 8) {
                swatches
            }
        }
    }

    private var swatches: some View {
        ForEach(library.all) { preset in
            Button {
                selection = preset.id
            } label: {
                VStack(spacing: 4) {
                    HookSwatch(style: preset.style)
                        .frame(width: 74, height: 46)
                        .clipShape(.rect(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(selection == preset.id ? Color.accentColor : .clear, lineWidth: 2.5)
                        }
                    Text(preset.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 74)
                        .foregroundStyle(selection == preset.id ? .primary : .secondary)
                }
            }
            .buttonStyle(.plain)
            .help(preset.name)
            .accessibilityLabel(preset.name)
            .accessibilityAddTraits(selection == preset.id ? .isSelected : [])
        }
    }
}

/// A real rendering of a hook style over a neutral backdrop, its text enlarged so the look reads at this size.
struct HookSwatch: View {
    let style: HookStyle

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            if let image = TextRenderer.hook(String(localized: "Hook"), style: sample, frameWidth: 184) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
            }
        }
    }

    private var sample: HookStyle {
        var style = style
        style.size = 0.16
        return style
    }
}

/// A real rendering of a caption style over a neutral backdrop.
struct CaptionSwatch: View {
    let style: CaptionStyle
    var sample = ["Make", "it", "pop"]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            if let image = TextRenderer.caption(words: sample, active: 1, style: style, frameWidth: 150) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            }
        }
    }
}

/// A number with its stepper arrows right beside it, trailing-aligned like other form values.
struct CountStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: LocalizedStringKey

    var body: some View {
        HStack(spacing: 4) {
            Text(value, format: .number)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(minWidth: 22, alignment: .trailing)
            Stepper(label, value: $value, in: range)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
    }
}

nonisolated enum LanguageList {
    static let codes = ["en", "id", "ms", "es", "pt", "fr", "de", "it", "nl", "tr", "ru", "ar", "hi", "th", "vi", "ja", "ko", "zh"]

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }

    static func looksLikeVideoLink(_ link: String) -> Bool {
        Downloader.isLink(link, onAnyOf: ["youtube.com", "youtu.be", "tiktok.com", "instagram.com", "x.com", "twitter.com", "facebook.com",
                                          "vimeo.com", "twitch.tv", "drive.google.com", "dailymotion.com"])
    }
}
