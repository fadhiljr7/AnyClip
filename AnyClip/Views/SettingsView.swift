//
//  SettingsView.swift
//  AnyClip
//

import SwiftUI
import FoundationModels
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(AppSettings.Key.settingsTab) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("AI", systemImage: "sparkles", value: "ai") { AISettings() }
            Tab("Transcription", systemImage: "waveform", value: "transcription") { TranscriptionSettings() }
            Tab("Watermark", systemImage: "signature", value: "watermark") { WatermarkSettingsView() }
            Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") { DownloadSettings() }
            Tab("YouTube", systemImage: "play.rectangle", value: "youtube") { YouTubeSettings() }
        }
        .frame(width: 580)
        .frame(minHeight: 440)
    }
}

struct GeneralSettings: View {
    @AppStorage(AppSettings.Key.exportFolder) private var exportFolder = ""
    @AppStorage(AppSettings.Key.videoCodec) private var codec = VideoCodec.h264
    @AppStorage(AppSettings.Key.exportShortSide) private var shortSide = 1080.0
    @AppStorage(AppSettings.Key.loopPreview) private var loopPreview = true
    @AppStorage(AppearanceMode.key) private var appearance = AppearanceMode.system.rawValue
    @State private var choosing = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Picker("Dark Mode", selection: $appearance) {
                    Text("System Default").tag(AppearanceMode.system.rawValue)
                    Text("On").tag(AppearanceMode.dark.rawValue)
                    Text("Off").tag(AppearanceMode.light.rawValue)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            } footer: {
                Text("System Default follows the appearance you’ve chosen in System Settings.")
                    .foregroundStyle(.secondary)
            }
            Section("Export") {
                LabeledContent("Save clips to") {
                    HStack {
                        Text(AppPaths.exportFolder.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { choosing = true }
                    }
                }
                if !exportFolder.isEmpty {
                    Button("Use Default Folder") { exportFolder = "" }
                }
                Picker("Resolution", selection: $shortSide) {
                    Text("720p").tag(720.0)
                    Text("1080p").tag(1080.0)
                    Text("1440p").tag(1440.0)
                    Text("4K").tag(2160.0)
                }
                Picker("Video format", selection: $codec) {
                    Text("H.264 (most compatible)").tag(VideoCodec.h264)
                    Text("HEVC (smaller files)").tag(VideoCodec.hevc)
                }
            }
            Section("Editor") {
                Toggle("Loop preview", isOn: $loopPreview)
            }
            Section {
                LabeledContent {
                    Button("Repeat Onboarding") { Onboarding.showTour(openWindow: openWindow) }
                } label: {
                    Text("Welcome tour")
                    Text("A short walk-through of the main window and how to make clips.")
                }
            }
            Section {
                LabeledContent("AnyClip", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                Text("Free to use. No account, no license key and no watermark of ours on your clips.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appearance) { AppearanceMode.apply() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { exportFolder = url.path(percentEncoded: false) }
        }
    }
}

struct AISettings: View {
    enum TestResult: Equatable {
        case connected
        case failed(String)
    }

    @AppStorage(AppSettings.Key.aiProvider) private var providerRaw = AIProvider.apple.rawValue
    @AppStorage(AppSettings.Key.allowPrivateCloud) private var allowPCC = true
    @State private var key = ""
    @State private var model = ""
    @State private var testResult: TestResult?
    @State private var keyError: String?
    @State private var testing = false
    @State private var hasKey = false
    @State private var checking = false
    @State private var modelResults: [String: CloudAI.ModelCheck] = [:]
    @AppStorage(AppSettings.Key.fallbackToApple) private var fallbackToApple = true
    @AppStorage(AIProvider.customBaseURLKey) private var baseURL = ""

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .apple }

    /// A key is saved and, for a custom provider, the base URL is a usable address.
    private var canConnect: Bool { hasKey && (provider != .custom || AIProvider.chatEndpoint(base: baseURL) != nil) }

    var body: some View {
        Form {
            Section {
                Picker("Find moments with", selection: $providerRaw) {
                    ForEach(AIProvider.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Text(provider.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if provider == .apple {
                Section("Apple Intelligence") {
                    LabeledContent("On this Mac", value: onDeviceStatus)
                    if AppEntitlements.privateCloudCompute {
                        Toggle("Use Private Cloud Compute for long videos", isOn: $allowPCC)
                        Text("Private Cloud Compute runs Apple’s larger model on Apple silicon servers. Your transcript isn’t stored or visible to Apple.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Text("Long videos are read in parts by the model on this Mac. When Apple Intelligence isn’t available, AnyClip uses built-in scoring that runs entirely on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    if provider == .custom {
                        TextField("Base URL", text: $baseURL, prompt: Text(verbatim: "https://api.example.com/v1"))
                            .textContentType(.URL)
                            .autocorrectionDisabled()
                        if let endpoint = AIProvider.chatEndpoint(base: baseURL) {
                            Text("Requests go to \(endpoint.absoluteString)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Text(baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "Enter the OpenAI-compatible address from your provider, usually ending in /v1."
                                 : "Enter a full address that starts with https://. Plain http:// only works for a server on this Mac or its local network.")
                                .font(.callout)
                                .foregroundStyle(baseURL.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : .primary)
                        }
                    }
                    SecureField("API key", text: $key, prompt: Text(hasKey ? "Saved in Keychain" : "Paste your key"))
                    HStack {
                        if let page = provider.keyPage {
                            Link("Get a key", destination: page)
                        }
                        Spacer()
                        if hasKey {
                            Button("Remove Key", role: .destructive) {
                                Keychain.delete(account: provider.rawValue)
                                hasKey = false
                                key = ""
                                testResult = nil
                            }
                        }
                        Button("Save Key") {
                            do {
                                try Keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: provider.rawValue)
                                keyError = nil
                                key = ""
                            } catch {
                                keyError = error.localizedDescription
                            }
                            hasKey = provider.apiKey != nil
                        }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let keyError {
                        WarningLabel(verbatim: keyError)
                    }
                    if let options = provider.modelOptions {
                        Picker("Model", selection: Binding(get: { provider.model }, set: { model = $0 })) {
                            ForEach(options, id: \.self) { id in
                                Group {
                                    if id == provider.defaultModel, provider != .custom { Text("\(id) (Recommended)") } else { Text(verbatim: id) }
                                }
                                .tag(id)
                            }
                        }
                        .onChange(of: model) { saveModel() }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button("Check Models") { checkModels(options) }
                                    .disabled(!canConnect || checking)
                                if checking { ProgressView().controlSize(.small) }
                                Spacer()
                            }
                            ForEach(options, id: \.self) { id in
                                if let result = modelResults[id] { ModelCheckRow(model: id, result: result) }
                            }
                        }
                    } else {
                        TextField("Model", text: $model, prompt: Text(provider.defaultModel))
                            .onSubmit { saveModel() }
                            .onChange(of: model) { saveModel() }
                    }
                    HStack {
                        Button("Test Connection") { test() }
                            .disabled(!canConnect || testing)
                        if testing { ProgressView().controlSize(.small) }
                        if testResult == .connected {
                            StatusLine("Connected", symbol: "checkmark.circle.fill", tint: .green)
                        }
                    }
                    if case .failed(let reason) = testResult {
                        WarningLabel(verbatim: reason)
                            .textSelection(.enabled)
                    }
                } header: {
                    if provider == .custom { Text("Connection") } else { Text("\(provider.displayName) API Key") }
                }
                Section {
                    Toggle("If \(provider.displayName) fails, use Apple Intelligence instead", isOn: $fallbackToApple)
                    Text(fallbackToApple
                         ? "The project page tells you when this happens and why \(provider.displayName) failed."
                         : "The project stops with the error from \(provider.displayName). Choose Try Again after fixing it — the video and transcript are reused.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Text("Your transcript is sent to \(provider.recipient) when you create a project. The key is stored in your Keychain and only sent to \(provider.recipient).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadProvider)
        .onChange(of: providerRaw) { loadProvider() }
        .onChange(of: baseURL) {
            testResult = nil
            modelResults = [:]
        }
    }

    private var onDeviceStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: String(localized: "Ready")
        case .unavailable(.appleIntelligenceNotEnabled): String(localized: "Turn on Apple Intelligence in System Settings")
        case .unavailable(.deviceNotEligible): String(localized: "Not supported on this Mac")
        case .unavailable(.modelNotReady): String(localized: "Downloading…")
        default: String(localized: "Unavailable")
        }
    }

    private func checkModels(_ models: [String]) {
        checking = true
        modelResults = [:]
        let p = provider
        Task {
            modelResults = await CloudAI.check(provider: p, models: models)
            checking = false
        }
    }

    private func loadProvider() {
        key = ""
        keyError = nil
        testResult = nil
        modelResults = [:]
        hasKey = provider.apiKey != nil
        model = UserDefaults.standard.string(forKey: AppSettings.Key.aiModel(provider)) ?? ""
    }

    private func saveModel() {
        UserDefaults.standard.set(model.trimmingCharacters(in: .whitespaces), forKey: AppSettings.Key.aiModel(provider))
    }

    private func test() {
        testing = true
        testResult = nil
        let p = provider
        Task {
            do {
                try await CloudAI.test(provider: p)
                testResult = .connected
            } catch {
                testResult = .failed(error.localizedDescription)
            }
            testing = false
        }
    }
}

struct ModelCheckRow: View {
    let model: String
    let result: CloudAI.ModelCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch result {
            case .working(let seconds):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(model).font(.callout.monospaced())
                Text("Works · \(seconds, format: .number.precision(.fractionLength(1))) s")
                    .font(.callout).foregroundStyle(.secondary)
            case .failed(let reason):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(model).font(.callout.monospaced())
                Text(reason).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct TranscriptionSettings: View {
    @AppStorage(WhisperModel.defaultsKey) private var modelRaw = WhisperModel.recommended.rawValue

    var body: some View {
        Form {
            Section {
                ForEach(TranscriptionMethod.allCases) { method in
                    Label {
                        Text(method.title)
                        Text(method.summary)
                    } icon: {
                        Image(systemName: method.symbol)
                    }
                }
            } header: {
                Text("Methods")
            } footer: {
                Text("Choose a method for each project under New Project › Video › Transcript.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Model", selection: $modelRaw) {
                    ForEach(WhisperModel.allCases) { m in
                        Text(m == .recommended ? "\(m.name) (Recommended)" : m.name).tag(m.rawValue)
                    }
                }
                ForEach(WhisperModel.allCases) { model in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(model.name).fontWeight(.medium)
                            Text(model.sizeText).foregroundStyle(.secondary).monospacedDigit()
                            Spacer()
                        }
                        Text(model.note).font(.caption).foregroundStyle(.secondary)
                        WhisperModelStatus(model: model, showsDelete: true)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("WhisperKit")
            } footer: {
                HStack {
                    Text("Each model is downloaded once and kept on this Mac. All of them understand Indonesian, English and 90+ other languages.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: WhisperModel.base, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(WhisperModel.base)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct WatermarkSettingsView: View {
    @State private var wm = WatermarkSettings.current
    @State private var choosingImage = false
    @State private var logoError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Add a watermark to exported clips", isOn: $wm.enabled)
            }
            Section("Content") {
                Picker("Type", selection: $wm.useImage) {
                    Text("Text").tag(false)
                    Text("Logo").tag(true)
                }
                .pickerStyle(.segmented)
                if wm.useImage {
                    LabeledContent("Logo") {
                        HStack {
                            if !wm.imagePath.isEmpty {
                                Text(URL(filePath: wm.imagePath).lastPathComponent).foregroundStyle(.secondary)
                            }
                            Button("Choose…") { choosingImage = true }
                        }
                    }
                    if let logoError {
                        WarningLabel(verbatim: logoError)
                    }
                } else {
                    TextField("Text", text: $wm.text, prompt: Text("@yourhandle"))
                }
            }
            .disabled(!wm.enabled)
            Section("Placement") {
                Picker("Position", selection: $wm.position) {
                    Text("Top Left").tag(WatermarkPosition.topLeading)
                    Text("Top Right").tag(WatermarkPosition.topTrailing)
                    Text("Bottom Left").tag(WatermarkPosition.bottomLeading)
                    Text("Bottom Right").tag(WatermarkPosition.bottomTrailing)
                    Text("Center").tag(WatermarkPosition.center)
                }
                LabeledContent("Size") { Slider(value: $wm.size, in: 0.08...0.4) }
                LabeledContent("Opacity") { Slider(value: $wm.opacity, in: 0.15...1) }
            }
            .disabled(!wm.enabled)
        }
        .formStyle(.grouped)
        .onChange(of: wm) { wm.save() }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.png, .jpeg, .heic, .image]) { result in
            if case .success(let url) = result {
                // Keep our own copy so the logo survives the original moving. A new name each time, so the old
                // logo stays in place if the copy fails.
                let dest = AppPaths.support.appending(path: "watermark-\(UUID().uuidString)." + url.pathExtension)
                do {
                    try FileManager.default.copyItem(at: url, to: dest)
                    if !wm.imagePath.isEmpty { try? FileManager.default.removeItem(atPath: wm.imagePath) }
                    wm.imagePath = dest.path(percentEncoded: false)
                    logoError = nil
                } catch {
                    logoError = error.localizedDescription
                }
            }
        }
    }
}

struct DownloadSettings: View {
    @AppStorage(AppSettings.Key.cookiesBrowser) private var cookiesBrowser = ""
    @AppStorage(AppSettings.Key.downloadHeight) private var downloadHeight = 1080
    @State private var tools = ToolManager.shared

    var body: some View {
        Form {
            Section {
                ForEach(Tool.allCases) { tool in
                    ToolRow(tool: tool, status: tools.status[tool], busy: tools.busy.contains(tool))
                }
                if let error = tools.lastError {
                    WarningLabel(verbatim: error)
                }
            } header: {
                Text("Tools")
            } footer: {
                HStack {
                    Text("Downloads stop working? Update yt-dlp first — sites change often.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Tools Folder") { NSWorkspace.shared.open(AppPaths.tools) }
                }
            }
            Section("Quality") {
                Picker("Download up to", selection: $downloadHeight) {
                    Text("720p").tag(720)
                    Text("1080p").tag(1080)
                    Text("1440p").tag(1440)
                    Text("4K").tag(2160)
                }
            }
            Section {
                Picker("Use cookies from", selection: $cookiesBrowser) {
                    Text("None").tag("")
                    Divider()
                    Text("Safari").tag("safari")
                    Text("Google Chrome").tag("chrome")
                    Text("Firefox").tag("firefox")
                    Text("Microsoft Edge").tag("edge")
                    Text("Brave").tag("brave")
                    Text("Arc").tag("chrome:~/Library/Application Support/Arc/User Data")
                }
            } header: {
                Text("Sign-in")
            } footer: {
                Text("For age-restricted or members-only videos, yt-dlp can use the sign-in from your browser. Cookies never leave this Mac. Safari requires Full Disk Access for AnyClip.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await tools.refresh() }
    }
}

struct ToolRow: View {
    let tool: Tool
    let status: ToolStatus?
    let busy: Bool

    var body: some View {
        LabeledContent {
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                } else if status?.path == nil {
                    if tool.canInstall {
                        Button("Install") { Task { try? await ToolManager.shared.install(tool) } }
                    } else {
                        Text("Not installed").foregroundStyle(.secondary)
                    }
                } else {
                    if tool.canInstall {
                        Button("Update") { Task { try? await ToolManager.shared.update(tool) } }
                    }
                    if status?.isOwnCopy == true {
                        Button("Remove", role: .destructive) { Task { await ToolManager.shared.remove(tool) } }
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: status?.path == nil ? "circle.dashed" : "checkmark.circle.fill")
                        .foregroundStyle(status?.path == nil ? Color.secondary : Color.green)
                    Text(tool.rawValue).fontWeight(.medium)
                    if let v = status?.version { Text(v).foregroundStyle(.secondary).font(.callout.monospacedDigit()) }
                }
                Text(tool.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let path = status?.path {
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}
