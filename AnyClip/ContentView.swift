//
//  ContentView.swift
//  AnyClip
//
//  Created by MUFIN on 19/10/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Bindable private var state = AppState.shared
    @Query(sort: \Project.createdAt, order: .reverse) private var projects: [Project]

    var body: some View {
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            SidebarView(selection: $state.selection, projects: projects)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            NavigationStack(path: $state.path) {
                detail
                    .navigationDestination(for: Clip.self) { clip in
                        ClipEditorView(clip: clip)
                    }
            }
        }
        .onChange(of: state.selection) { state.path = [] }
        .overlay { OnboardingOverlay() }
        .alert("Export Failed", isPresented: Binding(get: { Studio.shared.lastExportError != nil },
                                                     set: { if !$0 { Studio.shared.lastExportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(Studio.shared.lastExportError ?? "")
        }
        .task { Studio.shared.recoverInterrupted(projects) }
        .task {
            // Let the first layout settle so the spotlight lands on real controls.
            try? await Task.sleep(for: .milliseconds(700))
            #if DEBUG
            if UserDefaults.standard.string(forKey: "autotest")?.isEmpty == false { return }
            #endif
            Onboarding.shared.startIfNeeded(projects: projects)
        }
        .onChange(of: Onboarding.shared.pendingStart) { _, pending in
            if pending { Onboarding.shared.start(projects: projects) }
        }
        #if DEBUG
        .task { runAutotestIfRequested() }
        #endif
    }

    #if DEBUG
    @Environment(\.modelContext) private var context
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    /// `-autotest <url or path>` starts a project on launch; `-autoexport YES` exports the best clip.
    private func runAutotestIfRequested() {
        let projectsNow: @MainActor () -> [Project] = { [context] in
            (try? context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        }
        DebugDriver.openWindowAction = openWindow
        DebugDriver.start(projects: projectsNow, openSettings: { openSettings() })
        guard let target = UserDefaults.standard.string(forKey: "autotest"), !target.isEmpty else { return }
        var options = ProjectOptions()
        options.clipCount = UserDefaults.standard.integer(forKey: "autocount").clamped(to: 1...10)
        options.exportWhenDone = UserDefaults.standard.bool(forKey: "autoexport")
        if let method = UserDefaults.standard.string(forKey: "transcription").flatMap(TranscriptionMethod.init(rawValue:)) {
            options.transcription = method
        }
        options.transcriptLanguage = UserDefaults.standard.string(forKey: "transcriptLanguage")
        if UserDefaults.standard.object(forKey: "autobroll") != nil { options.broll = UserDefaults.standard.bool(forKey: "autobroll") }
        options.stacked = UserDefaults.standard.bool(forKey: "autostacked")
        let source: ProjectSource = target.hasPrefix("http") ? .url(target) : .file(URL(filePath: target))
        let project = Studio.shared.start(source, options: options, subtitleFile: nil, in: context)
        state.selection = .project(project.id)
    }
    #endif

    @ViewBuilder
    private var detail: some View {
        switch state.selection {
        case .create, .none:
            NewProjectView()
        case .allClips:
            LibraryView(filter: .all)
        case .hot:
            LibraryView(filter: .hot)
        case .saved:
            LibraryView(filter: .saved)
        case .project(let id):
            if let project = projects.first(where: { $0.id == id }) {
                ProjectView(project: project)
            } else {
                ContentUnavailableView("Project Not Found", systemImage: "questionmark.folder")
            }
        }
    }
}
