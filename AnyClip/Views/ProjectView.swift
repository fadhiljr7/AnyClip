//
//  ProjectView.swift
//  AnyClip
//

import SwiftUI
import SwiftData

struct ProjectView: View {
    let project: Project
    @Environment(\.modelContext) private var context
    @Environment(\.openSettings) private var openSettings
    @State private var sort: ClipSort = .score

    var body: some View {
        Group {
            if project.status == .failed || project.status == .cancelled, project.clips.isEmpty {
                failure
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        if let live = Studio.shared.live[project.id] {
                            PipelineProgress(project: project, live: live)
                        }
                        if !project.clips.isEmpty {
                            ClipGrid(clips: sorted(project.clips), showProject: false)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle(project.title)
        .navigationSubtitle(subtitle)
        .focusedSceneValue(\.selectedProject, project)
        .toolbar {
            ToolbarItemGroup {
                if !project.clips.isEmpty {
                    Menu("Sort", systemImage: "arrow.up.arrow.down") {
                        Picker("Sort", selection: $sort) {
                            Label("Best First", systemImage: "flame").tag(ClipSort.score)
                            Label("Video Order", systemImage: "clock").tag(ClipSort.time)
                        }
                        .pickerStyle(.inline)
                    }
                    .help("Sort clips")
                    Button("Export All", systemImage: "square.and.arrow.up.on.square") {
                        Studio.shared.export(project.sortedClips)
                    }
                    .help("Export every clip in this project (⇧⌘E)")
                }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if !project.channel.isEmpty { parts.append(project.channel) }
        if project.duration > 0 { parts.append(formatTimestamp(project.duration)) }
        if !project.language.isEmpty { parts.append(LanguageList.name(project.language)) }
        return parts.joined(separator: " · ")
    }

    private func sorted(_ clips: [Clip]) -> [Clip] {
        switch sort {
        case .score: clips.sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
        case .time: clips.sorted { $0.start < $1.start }
        }
    }

    @ViewBuilder
    private var header: some View {
        if project.status == .ready, !project.momentSource.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text(project.clips.count == 1 ? "1 moment found by \(project.momentSource). Open the clip to adjust its trim, captions and framing."
                                              : "\(project.clips.count) moments found by \(project.momentSource). Open a clip to adjust its trim, captions and framing.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if project.status == .ready, !project.transcriptSource.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text("Transcript: \(project.transcriptSource)")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        if project.status == .ready, let notice = project.transcriptNotice {
            NoticeBox(text: notice)
        }
        if project.status == .ready, let notice = project.momentNotice {
            NoticeBox(text: notice)
        }
        if project.status == .failed || project.status == .cancelled, !project.clips.isEmpty {
            // Stopped partway: what's here can be used, or the project can be made again from the start.
            HStack {
                NoticeBox(text: project.errorMessage ?? String(localized: "This project stopped before all its clips were made."))
                if Studio.shared.canRetry(project) {
                    Button("Make Clips Again") { Studio.shared.retry(project, context: context) }
                        .help("Replaces these clips with a new set. The video and transcript are reused.")
                }
            }
        }
    }

    private var failure: some View {
        ContentUnavailableView {
            Label(project.status == .cancelled ? "Stopped" : "Couldn’t Make Clips",
                  systemImage: project.status == .cancelled ? "stop.circle" : "exclamationmark.triangle")
        } description: {
            Text(project.errorMessage ?? String(localized: "The project was stopped before it finished."))
                .textSelection(.enabled)
            if !Studio.shared.canRetry(project) {
                Text("AnyClip has no copy of this video. Create a new project from the original file.")
            }
        } actions: {
            if Studio.shared.canRetry(project) {
                Button("Try Again") { Studio.shared.retry(project, context: context) }
                    .buttonStyle(.borderedProminent)
            }
            if project.status == .failed, !project.transcriptSource.isEmpty {
                // The transcript was made, so it stopped at the AI step: a rate limit, an overloaded model or a key.
                Button("AI Settings…") {
                    UserDefaults.standard.set("ai", forKey: AppSettings.Key.settingsTab)
                    openSettings()
                }
            } else if project.status == .failed, project.sourceURL != nil {
                Button("Download Settings…") {
                    UserDefaults.standard.set("downloads", forKey: AppSettings.Key.settingsTab)
                    openSettings()
                }
            }
        }
    }
}

enum ClipSort: Hashable { case score, time }

struct NoticeBox: View {
    let text: String

    var body: some View {
        Label {
            Text(text).textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

struct PipelineProgress: View {
    let project: Project
    let live: LiveProgress

    private var stages: [ProjectStatus] { project.pipelineStages }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            PosterImage(url: project.thumbnailURL, revision: live.stage)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 240)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 10) {
                if live.stage == .queued {
                    // Says why nothing is downloading yet, so a waiting project doesn't look stuck.
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ProjectStatus.queued.label)
                                .fontWeight(.semibold)
                            Text(Studio.shared.waitingReason(for: project) ?? "")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(stages, id: \.self) { stage in
                    StageRow(stage: stage, state: state(of: stage), fraction: stage == live.stage ? live.fraction : nil)
                }
                if live.stage != .queued {
                    Text(live.detail.isEmpty ? " " : live.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .contentTransition(.numericText())
                }
                HStack {
                    Button("Stop") { Studio.shared.cancel(project) }
                    Text("You can keep working while this runs. New projects wait their turn and start automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer()
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private func state(of stage: ProjectStatus) -> StageState {
        StageState.of(stage, current: live.stage, stages: stages)
    }
}

/// How far a project has come on one of its steps.
nonisolated enum StageState: Sendable {
    case pending, active, done

    /// A step not on the list (waiting in the queue, or a file being copied in) comes before all of them.
    static func of(_ stage: ProjectStatus, current: ProjectStatus, stages: [ProjectStatus]) -> StageState {
        guard let now = stages.firstIndex(of: current), let me = stages.firstIndex(of: stage) else { return .pending }
        return me < now ? .done : (me == now ? .active : .pending)
    }
}

struct StageRow: View {
    let stage: ProjectStatus
    let state: StageState
    let fraction: Double?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .active: ProgressView().controlSize(.small)
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18)
            Text(stage.label)
                .foregroundStyle(state == .pending ? .secondary : .primary)
                .fontWeight(state == .active ? .semibold : .regular)
            if state == .active, let fraction, fraction > 0 {
                ProgressView(value: fraction)
                    .frame(maxWidth: 160)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityState)
    }

    private var accessibilityState: Text {
        switch state {
        case .done: Text("Finished")
        case .active: Text("In progress")
        case .pending: Text("Not started")
        }
    }
}

// MARK: - Grid

struct ClipGrid: View {
    let clips: [Clip]
    var showProject = true

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 18, alignment: .top)],
                  alignment: .leading, spacing: 22) {
            ForEach(clips) { clip in
                NavigationLink(value: clip) {
                    ClipCard(clip: clip, showProject: showProject)
                        .background { if clip.id == clips.first?.id { Color.clear.tourTarget(.firstClip) } }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ClipCard: View {
    @Bindable var clip: Clip
    var showProject = true
    @State private var hovering = false
    @State private var retriedThumbnail = false
    @State private var confirmingDelete = false
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.title)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 4) {
                    Image(systemName: clip.category.symbol)
                    Text(showProject ? (clip.project?.title ?? clip.category.label) : clip.category.label)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(.rect)
        .task(id: clip.revision) {
            // A missing thumbnail (e.g. generation failed) is rebuilt instead of leaving a blank card.
            if !retriedThumbnail, let url = clip.thumbnailURL, clip.project?.status == .ready,
               !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                retriedThumbnail = true
                Studio.shared.refreshThumbnail(clip)
            }
        }
        .onHover { hovering = $0 }
        .scaleEffect(hovering && !reduceMotion ? 1.015 : 1)
        .animation(.snappy(duration: 0.18), value: hovering)
        .contextMenu {
            Button("Export Clip") { Studio.shared.export([clip]) }
            if let url = clip.exportedURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                ShareLink(item: url)
            }
            Button(clip.isSaved ? "Remove from Saved" : "Add to Saved") { clip.isSaved.toggle() }
            Button("Copy Title") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clip.title, forType: .string)
            }
            Divider()
            Button("Delete Clip…", role: .destructive) { confirmingDelete = true }
        }
        .confirmationDialog("Delete “\(clip.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Clip", role: .destructive) { Studio.shared.deleteClip(clip, context: context) }
        } message: {
            Text("The clip and your edits to it are removed from AnyClip. A video you already exported stays in your export folder.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(clip.title), \(formatDuration(clip.duration)), score \(Int(clip.score.rounded())) of 10")
        .accessibilityAction(named: clip.isSaved ? "Remove from Saved" : "Add to Saved") { clip.isSaved.toggle() }
        .accessibilityAction(named: "Export Clip") { Studio.shared.export([clip]) }
    }

    private var thumbnail: some View {
        PosterImage(url: clip.thumbnailURL, revision: clip.revision)
            .aspectRatio(clip.aspect.ratio < 1 ? clip.aspect.ratio : 1, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(alignment: .topLeading) { ScoreBadge(score: clip.score).padding(8) }
            .overlay(alignment: .topTrailing) {
                if clip.isSaved || hovering {
                    Button {
                        clip.isSaved.toggle()
                    } label: {
                        Image(systemName: clip.isSaved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.clear.interactive(), in: .circle)
                    .help(clip.isSaved ? "Remove from Saved" : "Add to Saved")
                    .padding(8)
                }
            }
            .overlay(alignment: .bottom) {
                HStack {
                    if let p = Studio.shared.exporting[clip.id] {
                        ProgressView(value: p)
                            .tint(.white)
                    } else if Studio.shared.isQueued(clip) {
                        Label("Waiting", systemImage: "clock").font(.caption2.weight(.semibold))
                    } else if clip.exportedURL != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .help("Exported")
                    }
                    Spacer()
                    Text(formatDuration(clip.duration))
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 3)
                .padding(10)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 54)
                }
                .clipShape(.rect(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
            }
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.1), radius: hovering ? 10 : 4, y: hovering ? 5 : 2)
    }
}

/// Virality score, 0–10. Hot clips (8+) carry a flame.
struct ScoreBadge: View {
    let score: Double

    var body: some View {
        HStack(spacing: 3) {
            if score >= 8 { Image(systemName: "flame.fill") }
            Text(score, format: .number.precision(.fractionLength(score.rounded() == score ? 0 : 1)))
        }
        .font(.caption.weight(.bold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(score >= 8 ? Color.accentColor : Color.black.opacity(0.55), in: .capsule)
        .accessibilityLabel("Score \(Int(score.rounded())) of 10")
    }
}

// MARK: - Library

struct LibraryView: View {
    enum Filter { case all, hot, saved }
    let filter: Filter
    @Query(sort: \Clip.createdAt, order: .reverse) private var clips: [Clip]
    @State private var search = ""

    private var filtered: [Clip] {
        var list = clips
        switch filter {
        case .all: break
        case .hot: list = list.filter(\.isHot).sorted { $0.score > $1.score }
        case .saved: list = list.filter(\.isSaved)
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.hook.localizedCaseInsensitiveContains(q)
                || ($0.project?.title.localizedCaseInsensitiveContains(q) ?? false) }
        }
        return list
    }

    private var title: LocalizedStringKey {
        switch filter {
        case .all: "All Clips"
        case .hot: "Hot"
        case .saved: "Saved"
        }
    }

    var body: some View {
        let filtered = filtered
        Group {
            if filtered.isEmpty {
                empty
            } else {
                ScrollView {
                    ClipGrid(clips: filtered)
                        .padding(24)
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $search, placement: .toolbar, prompt: "Search clips")
    }

    @ViewBuilder
    private var empty: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            switch filter {
            case .all:
                ContentUnavailableView {
                    Label("No Clips Yet", systemImage: "film.stack")
                } description: {
                    Text("Create a project from a link or a video file to get your first clips.")
                } actions: {
                    Button("New Project") { AppState.shared.selection = .create }
                }
            case .hot:
                ContentUnavailableView("No Hot Clips", systemImage: "flame",
                                       description: Text("Clips scoring 8 or higher show up here."))
            case .saved:
                ContentUnavailableView("Nothing Saved", systemImage: "bookmark",
                                       description: Text("Choose Add to Saved on a clip to keep it here."))
            }
        }
    }
}
