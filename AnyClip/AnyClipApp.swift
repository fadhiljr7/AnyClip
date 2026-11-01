//
//  AnyClipApp.swift
//  AnyClip
//
//  Created by MUFIN on 19/10/26.
//

import SwiftUI
import SwiftData

nonisolated enum SidebarItem: Hashable {
    case create
    case allClips
    case hot
    case saved
    case project(UUID)
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()
    var selection: SidebarItem? = .create
    var path: [Clip] = []
    var showFileImporter = false
    var columnVisibility: NavigationSplitViewVisibility = .all
    /// The project waiting for the delete confirmation in the sidebar.
    var projectToDelete: Project?
    /// The clipboard state last offered as a link, so the same link isn't filled in again and again.
    var lastClipboardChange: Int?
    /// The project whose clips are being scheduled for YouTube.
    var youtubeRequest: YouTubeUploadRequest?
}

/// Dark Mode in Settings › General: follow the system, or force dark or light.
enum AppearanceMode: String, CaseIterable {
    case system, dark, light

    static let key = "appearance"
    static var current: AppearanceMode { AppearanceMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    static func apply() {
        NSApp.appearance = switch current {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppearanceMode.apply()
    }

    /// Quitting stops whatever is being made, so it's worth asking first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Studio.shared.hasActiveWork else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit While Clips Are Being Made?")
        alert.informativeText = String(localized: "Projects and exports in progress will stop. You can use Try Again on a stopped project the next time you open AnyClip.")
        alert.addButton(withTitle: String(localized: "Keep Working"))
        alert.addButton(withTitle: String(localized: "Quit"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        Studio.shared.stopEverythingForQuit()
        AppStore.saveOnQuit()
    }
}

extension FocusedValues {
    @Entry var selectedClip: Clip?
    @Entry var selectedProject: Project?
    @Entry var editorActions: EditorActions?
}

/// What the Playback menu can do in the clip editor in front.
struct EditorActions {
    var togglePlay: () -> Void
    var step: (Double) -> Void
    var setStartToPlayhead: () -> Void
    var setEndToPlayhead: () -> Void
}

@main
struct AnyClipApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    var body: some Scene {
        WindowGroup("AnyClip", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(AppStore.container)
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            ToolbarCommands()
            InspectorCommands()
            AppCommands()
        }

        Settings {
            SettingsView()
        }
        .modelContainer(AppStore.container)
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.selectedClip) private var clip
    @FocusedValue(\.selectedProject) private var project
    @FocusedValue(\.editorActions) private var editor
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") {
                AppState.shared.path = []
                AppState.shared.selection = .create
            }
            .keyboardShortcut("n")
            Button("Import Video…") {
                AppState.shared.path = []
                AppState.shared.selection = .create
                AppState.shared.showFileImporter = true
            }
            .keyboardShortcut("o")
        }
        CommandMenu("Clip") {
            Button("Export Clip") {
                if let clip { Studio.shared.export([clip]) }
            }
            .keyboardShortcut("e")
            .disabled(clip == nil)
            Button("Export All Clips") {
                if let project { Studio.shared.export(project.sortedClips) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(project == nil || project?.clips.isEmpty == true)
            Divider()
            Button(clip?.isSaved == true ? "Remove from Saved" : "Add to Saved") {
                clip?.isSaved.toggle()
            }
            .keyboardShortcut("d")
            .disabled(clip == nil)
            Button("Show in Finder") {
                if let url = clip?.exportedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(clip?.exportedURL == nil)
            Divider()
            Button("Open Export Folder") {
                let folder = AppPaths.exportFolder
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
            }
            Button("Cancel Exports") { Studio.shared.cancelExports() }
                .disabled(!Studio.shared.isExporting)
        }
        CommandMenu("Project") {
            Button("Try Again") {
                if let project, let context = project.modelContext { Studio.shared.retry(project, context: context) }
            }
            .disabled(project.map(Studio.shared.offersTryAgain) != true)
            Button("Stop") { if let project { Studio.shared.cancel(project) } }
                .disabled(project.map(Studio.shared.isRunning) != true)
            Divider()
            Button("Upload to YouTube…") {
                if let project { AppState.shared.youtubeRequest = YouTubeUploadRequest(project: project, preselected: nil) }
            }
            .disabled(project?.clips.isEmpty != false)
            Divider()
            Button("Show Source in Finder") {
                if let project { NSWorkspace.shared.activateFileViewerSelecting([project.videoURL ?? project.folder]) }
            }
            .disabled(project == nil)
            Divider()
            Button("Delete Project…") { AppState.shared.projectToDelete = project }
                .disabled(project == nil)
        }
        CommandMenu("Playback") {
            Group {
                Button("Play or Pause") { editor?.togglePlay() }
                Button("Back 5 Seconds") { editor?.step(-5) }
                Button("Forward 5 Seconds") { editor?.step(5) }
                Divider()
                Button("Set Clip Start to Playhead") { editor?.setStartToPlayhead() }
                Button("Set Clip End to Playhead") { editor?.setEndToPlayhead() }
            }
            .disabled(editor == nil)
        }
        CommandGroup(replacing: .help) {
            Button("AnyClip Tour") { Onboarding.showTour(openWindow: openWindow) }
        }
    }
}
