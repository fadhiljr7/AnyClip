//
//  YouTubeViews.swift
//  AnyClip
//
//  Choosing clips and times for YouTube, connecting the account, and where each
//  clip stands in the upload queue.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct YouTubeUploadRequest: Identifiable {
    let id = UUID()
    let project: Project
    /// Opened from one clip: only that clip starts selected.
    let preselected: UUID?
}

struct YouTubeUploadSheet: View {
    let request: YouTubeUploadRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var selected: Set<UUID> = []
    @State private var first = AutoSchedule.suggestedFirst()
    @State private var every = 1
    @State private var unit = AutoSchedule.Unit.hours
    @State private var madeForKids = false
    private let account = YouTubeAccount.shared

    private var clips: [Clip] { request.project.sortedClips }
    private var schedule: AutoSchedule { AutoSchedule(first: first, every: every, unit: unit) }
    private var chosen: [Clip] { clips.filter { selected.contains($0.id) } }
    private var times: [UUID: Date] {
        Dictionary(uniqueKeysWithValues: zip(chosen.map(\.id), schedule.times(count: chosen.count)))
    }
    private var canSchedule: Bool { account.isConnected && !chosen.isEmpty && schedule.isInTime() }
    /// 24-hour time in the person's own language.
    private var locale24: Locale {
        var components = Locale.Components(locale: .current)
        components.hourCycle = .zeroToTwentyThree
        return Locale(components: components)
    }
    private var zoneName: String {
        let zone = TimeZone.current
        return "\(zone.identifier), \(zone.localizedName(for: .shortGeneric, locale: .current) ?? zone.abbreviation() ?? "")"
    }

    /// Clips not already on YouTube or on their way.
    private var fresh: [Clip] { clips.filter { $0.youtubeState != .scheduled && $0.youtubeState != .queued } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !account.isConnected {
                    Section {
                        LabeledContent {
                            Button("Open YouTube Settings…") {
                                UserDefaults.standard.set("youtube", forKey: AppSettings.Key.settingsTab)
                                openSettings()
                            }
                        } label: {
                            WarningLabel("Connect your YouTube account first.")
                        }
                    }
                }
                Section("Auto Schedule") {
                    DatePicker("First video", selection: $first, displayedComponents: [.date, .hourAndMinute])
                        .environment(\.locale, locale24)
                    LabeledContent("Then one every") {
                        HStack(spacing: 8) {
                            CountStepper(value: $every, range: 1...999, label: "Interval")
                            Picker("Unit", selection: $unit) {
                                Text("Minutes").tag(AutoSchedule.Unit.minutes)
                                Text("Hours").tag(AutoSchedule.Unit.hours)
                                Text("Days").tag(AutoSchedule.Unit.days)
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    if !schedule.isInTime() {
                        WarningLabel("Choose a time at least 15 minutes from now, so there’s time to render and upload.")
                    }
                    Text("Times use your time zone: \(zoneName).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach(clips) { clip in
                        YouTubeClipRow(clip: clip, time: times[clip.id], isOn: Binding(
                            get: { selected.contains(clip.id) },
                            set: { on in if on { selected.insert(clip.id) } else { selected.remove(clip.id) } }))
                    }
                } header: {
                    HStack {
                        Text("Clips")
                        Spacer()
                        Button("Select All") { selected = Set(fresh.map(\.id)) }
                            .buttonStyle(.link)
                        Button("Select None") { selected = [] }
                            .buttonStyle(.link)
                    }
                }
                Section {
                    Picker("Audience", selection: $madeForKids) {
                        Text("Not made for kids").tag(false)
                        Text("Made for kids").tag(true)
                    }
                } footer: {
                    Text("Each clip’s title and caption are used. Clips are rendered as they are now and uploaded as private, and YouTube makes them public at their time, even if this Mac is off. Keep AnyClip open until the uploads finish. To show your thumbnail on a Short, upload it in YouTube Studio.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Schedule 1 Video" : "Schedule \(chosen.count) Videos") {
                    YouTubeUploads.shared.schedule(chosen, at: schedule.times(count: chosen.count), madeForKids: madeForKids)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSchedule)
            }
            .padding(16)
        }
        .frame(width: 620, height: 660)
        .onAppear {
            if let one = request.preselected {
                selected = [one]
            } else {
                selected = Set(fresh.map(\.id))
            }
        }
    }
}

private struct YouTubeClipRow: View {
    let clip: Clip
    let time: Date?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                PosterImage(url: clip.thumbnailURL, revision: clip.revision)
                    .frame(width: 34, height: 60)
                    .clipShape(.rect(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.title).lineLimit(2)
                    if let time {
                        Text(verbatim: YouTubeTime.display(time))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.tint)
                    } else if clip.youtubeState == .scheduled, let at = clip.youtubePublishAt {
                        Text("Already scheduled for \(YouTubeTime.display(at))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(clip.youtubeState == .queued)
    }
}

/// A small mark on a clip's card.
struct YouTubeBadge: View {
    let clip: Clip

    var body: some View {
        switch clip.youtubeState {
        case .queued:
            Image(systemName: "icloud.and.arrow.up")
                .help("Uploading to YouTube")
                .accessibilityLabel("Uploading to YouTube")
        case .scheduled:
            let time = clip.youtubePublishAt.map { YouTubeTime.display($0) } ?? ""
            Image(systemName: "play.rectangle.fill")
                .help("Scheduled on YouTube for \(time)")
                .accessibilityLabel("Scheduled on YouTube for \(time)")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .help(clip.youtubeError ?? "")
                .accessibilityLabel("YouTube upload failed")
        case nil:
            EmptyView()
        }
    }
}

/// Where a clip stands on YouTube, in the editor's Details tab.
struct YouTubeClipSection: View {
    let clip: Clip
    private let uploads = YouTubeUploads.shared

    private func request() -> YouTubeUploadRequest? {
        clip.project.map { YouTubeUploadRequest(project: $0, preselected: clip.id) }
    }

    var body: some View {
        Section("YouTube") {
            switch clip.youtubeState {
            case .queued:
                progress
                Button("Cancel Upload") { uploads.cancel(clip) }
            case .scheduled:
                if let at = clip.youtubePublishAt {
                    LabeledContent("Publishes", value: YouTubeTime.display(at))
                }
                if let url = clip.youtubeURL { Link("Open on YouTube", destination: url) }
                if let notice = clip.youtubeNotice { WarningLabel(verbatim: notice) }
            case .failed:
                WarningLabel(verbatim: clip.youtubeError ?? "")
                scheduleButton("Schedule Again…")
            case nil:
                scheduleButton("Upload to YouTube…")
            }
        }
    }

    private func scheduleButton(_ title: LocalizedStringKey) -> some View {
        Button(title) { AppState.shared.youtubeRequest = request() }
    }

    @ViewBuilder
    private var progress: some View {
        switch uploads.phase(of: clip) {
        case .rendering:
            LabeledContent("Status") { ProgressView().controlSize(.small) }
            Text("Rendering the video…").font(.callout).foregroundStyle(.secondary)
        case .uploading(let fraction):
            ProgressView("Uploading to YouTube…", value: fraction)
        case .thumbnail:
            LabeledContent("Status", value: String(localized: "Setting the thumbnail…"))
        case .waiting, nil:
            if let until = uploads.pausedUntil {
                Text("YouTube’s daily limit is used up. Uploads carry on at \(YouTubeTime.display(until)) while AnyClip is open.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LabeledContent("Status", value: String(localized: "Waiting in queue"))
            }
        }
    }
}

struct YouTubeSettings: View {
    @State private var clientID = YouTubeCredentials.clientID ?? ""
    @State private var clientSecret = YouTubeCredentials.clientSecret ?? ""
    @State private var importing = false
    @State private var saveError: String?
    private let account = YouTubeAccount.shared

    private var hasClient: Bool { !clientID.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            Section {
                if account.isConnected {
                    LabeledContent {
                        Button("Disconnect", role: .destructive) { account.disconnect() }
                    } label: {
                        StatusLine(verbatim: account.channelName.isEmpty ? String(localized: "Connected") : account.channelName,
                                   symbol: "checkmark.circle.fill", tint: .green)
                    }
                } else if account.isConnecting {
                    LabeledContent {
                        Button("Cancel") { account.cancelConnecting() }
                    } label: {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for you to sign in, in your browser…")
                        }
                    }
                } else {
                    LabeledContent("YouTube account") {
                        Button("Connect…") {
                            save()
                            account.connect()
                        }
                        .disabled(!hasClient)
                    }
                }
                if let error = account.lastError ?? saveError {
                    WarningLabel(verbatim: error)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("AnyClip only asks to upload videos and read your channel’s name. Sign-in stays in your Keychain, and nothing passes through any AnyClip server.")
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Client ID", text: $clientID, prompt: Text(verbatim: "…apps.googleusercontent.com"))
                    .autocorrectionDisabled()
                SecureField("Client secret", text: $clientSecret, prompt: Text("Optional"))
                HStack {
                    Button("Import Client File…") { importing = true }
                    Spacer()
                    Button("Save") { save() }
                        .disabled(!hasClient)
                }
            } header: {
                Text("Your Google Client")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("YouTube requires each app to have a Google client. As an open-source app, AnyClip uses your own, for free. In Google Cloud: create a project, enable YouTube Data API v3, set up the OAuth consent screen and add your account as a test user, then create an OAuth client of type Desktop app.")
                    Link("Open Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { if account.isConnected { await account.refreshChannelName() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result, let data = try? Data(contentsOf: url),
                  let client = YouTubeCredentials.parseClientFile(data) else {
                saveError = String(localized: "That file isn’t a Google client file.")
                return
            }
            clientID = client.id
            clientSecret = client.secret
            save()
        }
    }

    private func save() {
        do {
            try YouTubeCredentials.saveClient(id: clientID, secret: clientSecret)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
