//
//  SidebarView.swift
//  AnyClip
//

import SwiftUI
import SwiftData

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    let projects: [Project]
    @Environment(\.modelContext) private var context
    @Query private var clips: [Clip]
    @Bindable private var state = AppState.shared

    var body: some View {
        List(selection: $selection) {
            Label("New Project", systemImage: "plus.square.on.square")
                .tourTarget(.sidebarNewProject)
                .tag(SidebarItem.create)

            Section("Library") {
                Label("All Clips", systemImage: "square.grid.2x2")
                    .badge(clips.count)
                    .tourTarget(.sidebarLibrary)
                    .tag(SidebarItem.allClips)
                Label("Hot", systemImage: "flame")
                    .badge(clips.filter(\.isHot).count)
                    .tourTarget(.sidebarLibrary)
                    .tag(SidebarItem.hot)
                Label("Saved", systemImage: "bookmark")
                    .badge(clips.filter(\.isSaved).count)
                    .tourTarget(.sidebarLibrary)
                    .tag(SidebarItem.saved)
            }

            Section("Projects") {
                if projects.isEmpty {
                    Text("Projects you create appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                        .tourTarget(.sidebarProjects)
                }
                ForEach(projects) { project in
                    ProjectRow(project: project)
                        .tourTarget(.sidebarProjects)
                        .tag(SidebarItem.project(project.id))
                        .contextMenu {
                            Button("Show Source in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([project.videoURL ?? project.folder])
                            }
                            if Studio.shared.offersTryAgain(project) {
                                Button("Try Again") { Studio.shared.retry(project, context: context) }
                            }
                            if Studio.shared.isRunning(project) {
                                Button("Stop") { Studio.shared.cancel(project) }
                            }
                            Divider()
                            Button("Delete Project…", role: .destructive) { state.projectToDelete = project }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if case .project(let id) = selection { state.projectToDelete = projects.first { $0.id == id } }
        }
        .confirmationDialog("Delete “\(state.projectToDelete?.title ?? "")”?", isPresented: Binding(
            get: { state.projectToDelete != nil }, set: { if !$0 { state.projectToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Project", role: .destructive) { deleteProject(includeExports: false) }
            if state.projectToDelete?.clips.contains(where: { $0.exportedURL != nil }) == true {
                Button("Delete Project and Exported Clips", role: .destructive) { deleteProject(includeExports: true) }
            }
        } message: {
            Text("The downloaded video, transcript and clips are permanently removed from AnyClip. Exported clips stay in your export folder unless you choose to delete them too — they’re moved to the Trash.")
        }
    }
}

extension SidebarView {
    fileprivate func deleteProject(includeExports: Bool) {
        if let p = state.projectToDelete {
            if selection == .project(p.id) { selection = .create }
            // A clip of this project may be open from the library.
            state.path.removeAll { $0.project?.id == p.id }
            Studio.shared.delete(p, context: context, includeExports: includeExports)
        }
        state.projectToDelete = nil
    }
}

struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            PosterImage(url: project.thumbnailURL, revision: project.statusRaw)
                .frame(width: 44, height: 28)
                .clipShape(.rect(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(project.title)
                    .lineLimit(1)
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if Studio.shared.isWaiting(project) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .help(Studio.shared.waitingReason(for: project) ?? "")
                    .accessibilityHidden(true)
            } else if let live = Studio.shared.live[project.id] {
                // The whole project, not the current step: the step's own bar is on the project page.
                ProgressView(value: live.overall(stages: project.pipelineStages))
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(Color.accentColor)
            } else if project.status == .failed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(project.errorMessage ?? "")
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var subtitle: some View {
        if let live = Studio.shared.live[project.id] {
            Text(live.stage.label)
        } else if project.status == .ready {
            Text(project.clips.count == 1 ? "1 clip · \(formatTimestamp(project.duration))"
                                          : "\(project.clips.count) clips · \(formatTimestamp(project.duration))")
        } else {
            Text(project.status.label)
        }
    }
}

/// Loads a JPEG from disk off the main thread.
struct PosterImage: View {
    let url: URL?
    var revision: AnyHashable = 0
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "film")
                    .foregroundStyle(.tertiary)
            }
        }
        .clipped()
        .task(id: TaskKey(url: url, revision: revision)) {
            guard let url else { return }
            image = await Task.detached { NSImage(contentsOf: url) }.value
        }
    }

    private struct TaskKey: Hashable {
        var url: URL?
        var revision: AnyHashable
    }
}
