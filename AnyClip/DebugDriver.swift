//
//  DebugDriver.swift
//  AnyClip
//
//  DEBUG builds only: lets UI tests drive navigation and capture windows by
//  writing commands to `<debugdir>/cmd`. Not compiled into Release.
//

#if DEBUG
import SwiftUI
import SwiftData

@MainActor
enum DebugDriver {
    private static var timer: Timer?
    private static var queue: [String] = []
    private static var busyUntil = Date.distantPast
    static var openWindowAction: OpenWindowAction?
    static let suggestHooks = Notification.Name("AnyClipDebugSuggestHooks")
    static let teaserChosen = Notification.Name("AnyClipDebugTeaserChosen")
    static let showStackIntro = Notification.Name("AnyClipDebugShowStackIntro")
    static let hookLook = Notification.Name("AnyClipDebugHookLook")

    static func start(projects: @escaping @MainActor () -> [Project], openSettings: @escaping @MainActor () -> Void) {
        guard timer == nil, let dir = UserDefaults.standard.string(forKey: "debugdir") else { return }
        let cmdURL = URL(filePath: dir).appending(path: "cmd")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let text = try? String(contentsOf: cmdURL, encoding: .utf8) {
                    try? FileManager.default.removeItem(at: cmdURL)
                    queue += text.split(separator: "\n").map(String.init)
                }
                guard Date() >= busyUntil, !queue.isEmpty else { return }
                run(queue.removeFirst(), dir: dir, projects: projects(), openSettings: openSettings)
            }
        }
    }

    private static func run(_ line: String, dir: String, projects: [Project], openSettings: () -> Void) {
        let parts = line.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return }
        let state = AppState.shared
        busyUntil = Date().addingTimeInterval(1.2)
        switch cmd {
        case "create": state.path = []; state.selection = .create
        case "all": state.selection = .allClips
        case "hot": state.selection = .hot
        case "saved": state.selection = .saved
        case "project":
            let i = Int(parts.dropFirst().first ?? "0") ?? 0
            if i < projects.count { state.selection = .project(projects[i].id) }
        case "editor":
            let i = Int(parts.dropFirst().first ?? "0") ?? 0
            if case .project(let id) = state.selection, let p = projects.first(where: { $0.id == id }), i < p.sortedClips.count {
                state.path = [p.sortedClips[i]]
            }
            busyUntil = Date().addingTimeInterval(3)
        case "back": state.path = []
        case "settings":
            if let tab = parts.dropFirst().first { UserDefaults.standard.set(tab, forKey: "settingsTab") }
            openSettings()
        case "close-settings":
            NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true || $0.title.contains("Settings") || $0.title.contains("Pengaturan") }?.close()
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "size":
            if parts.count == 3, let w = Double(parts[1]), let h = Double(parts[2]), let win = mainWindow {
                win.setContentSize(NSSize(width: w, height: h))
            }
        case "wait": busyUntil = Date().addingTimeInterval(Double(parts.dropFirst().first ?? "1") ?? 1)
        case "snap":
            let name = parts.dropFirst().first ?? "snap.png"
            let which = parts.count > 2 ? parts[2] : "main"
            let window = which == "settings" ? NSApp.windows.first { $0 !== mainWindow && $0.isVisible && $0.frame.width > 300 }
                : which == "sheet" ? mainWindow?.attachedSheet : mainWindow
            if let window { snapshot(window, to: URL(filePath: dir).appending(path: name)) }
        case "wm":
            var wm = WatermarkSettings.current
            wm.enabled = parts.count > 1
            wm.text = parts.dropFirst().joined(separator: " ")
            wm.save()
        case "seek":
            PreviewController.debugCurrent?.seek(toClipTime: Double(parts.dropFirst().first ?? "0") ?? 0)
        case "brollstyle":
            // brollstyle <style> <clip index>: sets every card in the clip to that style
            let index = Int(parts.last ?? "0") ?? 0
            if case .project(let id) = state.selection, let p = projects.first(where: { $0.id == id }), index < p.sortedClips.count,
               parts.count > 2, let style = BRollStyle(rawValue: parts[1]) {
                let clip = p.sortedClips[index]
                clip.broll = clip.broll.map { var b = $0; b.style = style; b.duration = style.kind == .full ? BRollInsert.fullDuration : BRollInsert.overlayDuration; return b }
            }
        case "style", "export":
            // style <preset> <clip index> / export <clip index>
            let index = Int(parts.last ?? "0") ?? 0
            if case .project(let id) = state.selection, let p = projects.first(where: { $0.id == id }), index < p.sortedClips.count {
                let clip = p.sortedClips[index]
                if cmd == "style", parts.count > 1 { clip.captionStyle = CaptionPreset.preset(parts[1]).style }
                if cmd == "export" { Studio.shared.export([clip]) }
            }
        case "delete":
            // delete <index> [exports]
            let i = Int(parts.dropFirst().first ?? "0") ?? 0
            if i < projects.count, let context = projects[i].modelContext {
                state.selection = .create
                Studio.shared.delete(projects[i], context: context, includeExports: parts.contains("exports"))
            }
        case "splits":
            // Logs the width of every split view pane in the main window, to catch layout jumps.
            func splits(in view: NSView) -> [NSSplitView] {
                ((view as? NSSplitView).map { [$0] } ?? []) + view.subviews.flatMap(splits)
            }
            if let content = mainWindow?.contentView {
                let widths = splits(in: content).map { $0.arrangedSubviews.map { Int($0.frame.width) } }
                FileHandle.standardError.write(Data("[AnyClip layout] \(parts.dropFirst().joined(separator: " ")) \(widths)\n".utf8))
            }
        case "layers":
            FileHandle.standardError.write(Data("[AnyClip layers]\n\(PreviewNSView.debugCurrent?.debugTree() ?? "no preview")\n".utf8))
        case "hooklook":
            // hooklook <card|strip|sideAccent|outline>: picks the look in the open Hook tab
            if let look = parts.dropFirst().first { NotificationCenter.default.post(name: hookLook, object: look) }
        case "stackintro":
            // stackintro reset | show
            if parts.dropFirst().first == "show" {
                NotificationCenter.default.post(name: showStackIntro, object: nil)
            } else {
                UserDefaults.standard.removeObject(forKey: StackedLayoutIntro.acknowledgedKey)
            }
        case "retry":
            // retry: Try Again on the selected project
            if case .project(let id) = state.selection, let p = projects.first(where: { $0.id == id }), let context = p.modelContext {
                Studio.shared.debugLog("retrying \(p.title)")
                Studio.shared.retry(p, context: context)
            }
        case "scroll":
            // scroll <y>: scrolls the biggest scroll view in the main window to y points from the top
            func scrollViews(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
            }
            if let content = mainWindow?.contentView,
               let scroll = scrollViews(in: content).max(by: { $0.frame.height < $1.frame.height }) {
                let y = Double(parts.dropFirst().first ?? "0") ?? 0
                scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.isFlipped ? y : max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height - y)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        case "stop":
            // stop: Stop on the selected project, which also takes a waiting project out of the queue
            if case .project(let id) = state.selection, let p = projects.first(where: { $0.id == id }) {
                Studio.shared.debugLog("stopping \(p.title), waiting \(Studio.shared.isWaiting(p))")
                Studio.shared.cancel(p)
            }
        case "teasertest":
            // teasertest <project index> <from s> <to s> [rough]: runs the teaser finder on part of a transcript, saves nothing
            busyUntil = Date().addingTimeInterval(120)
            let i = Int(parts.dropFirst().first ?? "0") ?? 0
            guard parts.count >= 4, i < projects.count, let from = Double(parts[2]), let to = Double(parts[3]),
                  let transcript = Studio.shared.transcript(for: projects[i]), let video = projects[i].videoURL else { busyUntil = .distantPast; return }
            let project = projects[i]
            var words = transcript.words(in: from...to)
            if parts.contains("rough") {
                // Like a subtitle file: each line's words spread evenly, ignoring real timing.
                var spread: [Word] = []
                for line in Transcript(language: transcript.language, words: words).lines(minSeconds: 2, maxSeconds: 6) {
                    let lineWords = words.filter { $0.start >= line.start - 0.001 && $0.end <= line.end + 0.001 }
                    let step = (line.end - line.start) / Double(max(lineWords.count, 1))
                    for (k, w) in lineWords.enumerated() {
                        spread.append(Word(text: w.text, start: line.start + Double(k) * step, end: line.start + Double(k + 1) * step))
                    }
                }
                words = spread
            }
            let request = TeaserRequest(words: words, clipStart: from, clipEnd: to, title: project.title, hook: "",
                                        language: transcript.language, media: project.audioURL ?? video,
                                        preciseTiming: !parts.contains("rough"))
            Task {
                let log = { (m: String) in FileHandle.standardError.write(Data("[AnyClip teaser] \(m)\n".utf8)) }
                log("== \(project.title.prefix(30)) \(from)–\(to)\(parts.contains("rough") ? " rough" : "")")
                do {
                    let provider = parts.contains("apple") ? AIProvider.apple : AIProvider.selected
                    let result = try await TeaserFinder.find(request, provider: provider, useAI: !parts.contains("noai"))
                    log("source \(result.source) notice \(result.notice ?? "-")")
                    for c in result.candidates {
                        let inside = words.filter { ($0.start + $0.end) / 2 > c.start && ($0.start + $0.end) / 2 < c.end }.map(\.text).joined(separator: " ")
                        log(String(format: "%@ %.2f–%.2f (+%.1f, %.1f s) score %.0f [%@] “%@” words-in-cut “%@” – %@", c.angle.rawValue, c.start, c.end,
                                   c.start - from, c.duration, c.score, c.warnings.map(\.rawValue).joined(separator: ","), c.text, inside, c.reason))
                    }
                } catch {
                    log("error \(error.localizedDescription)")
                }
                busyUntil = .distantPast
            }
        case "teaser":
            // teaser <clip index> find | use <n> | on | off | nudge <startDelta> <endDelta>
            let index = Int(parts.dropFirst().first ?? "0") ?? 0
            guard case .project(let id) = state.selection, let p = projects.first(where: { $0.id == id }), index < p.sortedClips.count else { return }
            let clip = p.sortedClips[index]
            switch parts.count > 2 ? parts[2] : "" {
            case "find":
                busyUntil = Date().addingTimeInterval(120)
                Task {
                    await Studio.shared.refreshTeasers(for: clip).value
                    busyUntil = .distantPast
                }
            case "use":
                // Same as Use as Teaser in the editor, including the hook check that follows it.
                let n = Int(parts.count > 3 ? parts[3] : "0") ?? 0
                var plan = clip.teaser
                if n < plan.candidates.count { plan.select(plan.candidates[n]) }
                clip.teaser = plan
                clip.teaserEnabled = true
                NotificationCenter.default.post(name: teaserChosen, object: nil)
            case "findtwice":
                // Two requests in a row must share one search.
                busyUntil = Date().addingTimeInterval(120)
                let first = Studio.shared.refreshTeasers(for: clip)
                let second = Studio.shared.refreshTeasers(for: clip)
                Studio.shared.debugLog("teaser requests share one task: \(first == second)")
                Task {
                    await second.value
                    Studio.shared.debugLog("teaser search running after finish: \(Studio.shared.isFindingTeasers(clip))")
                    busyUntil = .distantPast
                }
            case "hooks":
                NotificationCenter.default.post(name: suggestHooks, object: nil)
            case "trim":
                // teaser <clip> trim <start offset>: moves the clip start, to test a teaser falling outside the trim
                clip.start += Double(parts.count > 3 ? parts[3] : "0") ?? 0
            case "broll": clip.brollEnabled = parts.count > 3 && parts[3] == "on"
            case "on": clip.teaserEnabled = true
            case "off": clip.teaserEnabled = false
            default: break
            }
            PreviewController.debugCurrent?.update(for: clip, playFromStart: false)
            Studio.shared.debugLog("teaser clip \(index): enabled \(clip.teaserEnabled) active \(String(describing: clip.activeTeaser)) candidates \(clip.teaser.candidates.count)")
        case "stack":
            // stack <clip> on | off | swap on|off | info | probe | range <start> <end>
            let index = Int(parts.dropFirst().first ?? "0") ?? 0
            guard case .project(let id) = state.selection, let p = projects.first(where: { $0.id == id }), index < p.sortedClips.count else { return }
            let clip = p.sortedClips[index]
            let log = { (m: String) in Studio.shared.debugLog("stack clip \(index): \(m)") }
            func report() {
                log("verdict \(String(describing: clip.twoSpeaker)) on \(clip.stackedLayout) swapped \(clip.stackSwapped) captionY \(clip.captionStyle.positionY) samples \(clip.shots?.samples.count ?? 0) cuts \(clip.shots?.cuts.map { String(format: "%.3f", $0) } ?? [])")
                for seg in clip.stackPlan ?? [] {
                    if case .stacked(let top, let bottom) = seg.layout {
                        log(String(format: "  stacked %.3f–%.3f top x %.2f bottom x %.2f", seg.start, seg.end, top.x, bottom.x))
                    } else {
                        log(String(format: "  full %.3f–%.3f", seg.start, seg.end))
                    }
                }
            }
            switch parts.count > 2 ? parts[2] : "info" {
            case "on": clip.setStacked(true)
            case "off": clip.setStacked(false)
            case "swap":
                clip.stackSwapped = parts.count > 3 ? parts[3] == "on" : !clip.stackSwapped
                clip.markChanged()
            case "probe", "range":
                // probe: analyses the clip and logs the result without saving it; range also moves the clip and saves.
                guard let video = p.videoURL else { return }
                let saving = parts[2] == "range"
                if saving, parts.count > 4, let a = Double(parts[3]), let b = Double(parts[4]) { clip.start = a; clip.end = b }
                busyUntil = Date().addingTimeInterval(120)
                let started = Date()
                Task {
                    let faces = await FaceTracker.analyze(video: video, range: clip.start...clip.end, aspect: clip.aspect)
                    log(String(format: "analysed %.0f s in %.2f s", clip.end - clip.start, Date().timeIntervalSince(started)))
                    if let shots = faces.shots {
                        let range = ClipSegment(start: clip.start, end: clip.end)
                        log("probe verdict \(TwoSpeaker.suitability(shots, range: range)) cuts \(shots.cuts.map { String(format: "%.3f", $0) })")
                        for seg in TwoSpeaker.segments(shots, range: range) {
                            log(String(format: "  %@ %.3f–%.3f", seg.isStacked ? "stacked" : "full", seg.start, seg.end))
                        }
                    }
                    if saving {
                        clip.keyframes = faces.keyframes
                        clip.shots = faces.shots
                        clip.markChanged()
                        report()
                        PreviewController.debugCurrent?.update(for: clip, playFromStart: false)
                    }
                    busyUntil = .distantPast
                }
                return
            default: break
            }
            report()
            PreviewController.debugCurrent?.update(for: clip, playFromStart: false)
        case "play":
            PreviewController.debugCurrent?.togglePlay()
        case "checkmodels":
            busyUntil = Date().addingTimeInterval(60)
            // checkmodels [provider], Gemini by default
            let provider = AIProvider(rawValue: parts.dropFirst().first ?? "") ?? .gemini
            Task {
                if provider == .gemini {
                    let listed = await CloudAI.availableGeminiModels()
                    let flash = listed?.filter { $0.contains("gemini") }.sorted().joined(separator: ", ") ?? "list unavailable"
                    FileHandle.standardError.write(Data("[AnyClip models] offered to key: \(flash)\n".utf8))
                }
                let results = await CloudAI.check(provider: provider, models: provider.modelOptions ?? [])
                for (model, result) in results.sorted(by: { $0.key < $1.key }) {
                    FileHandle.standardError.write(Data("[AnyClip models] \(model): \(result)\n".utf8))
                }
                busyUntil = .distantPast
            }
        case "tour":
            // tour [next|prev|skip|reset]
            switch parts.dropFirst().first {
            case "next": Onboarding.shared.next()
            case "prev": Onboarding.shared.previous()
            case "skip": Onboarding.shared.finish()
            case "dump": Onboarding.shared.dump()
            case "show": Onboarding.showTour(openWindow: openWindowAction!)
            case "reset": UserDefaults.standard.removeObject(forKey: Onboarding.completedKey)
            default: Onboarding.shared.start(projects: projects)
            }
        case "appearance":
            UserDefaults.standard.set(parts.dropFirst().first ?? "system", forKey: AppearanceMode.key)
            AppearanceMode.apply()
        case "method":
            // method <apple|youtube|subtitleFile|whisper>: reopens New Project with that method
            let data = UserDefaults.standard.data(forKey: "lastOptions") ?? Data()
            var options = (try? JSONDecoder().decode(ProjectOptions.self, from: data)) ?? ProjectOptions()
            options.transcription = TranscriptionMethod(rawValue: parts.dropFirst().first ?? "") ?? .apple
            UserDefaults.standard.set(try? JSONEncoder().encode(options), forKey: "lastOptions")
            state.selection = .allClips
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { AppState.shared.selection = .create }
        case "paste":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(parts.dropFirst().joined(separator: " "), forType: .string)
        case "newproject":
            // newproject <url> [stacked]: starts a project with the options last used in New Project
            guard parts.count > 1, let context = projects.first?.modelContext else { return }
            let saved = UserDefaults.standard.data(forKey: "lastOptions") ?? Data()
            var options = (try? JSONDecoder().decode(ProjectOptions.self, from: saved)) ?? ProjectOptions()
            options.stacked = parts.count > 2 && parts[2] == "stacked"
            options.transcriptLanguage = nil
            let project = Studio.shared.start(.url(parts[1]), options: options, subtitleFile: nil, in: context)
            state.selection = .project(project.id)
        case "quit": NSApp.terminate(nil)
        case "stopall": Studio.shared.stopEverythingForQuit()
        default: break
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.frame.width > 700 && $0.title != "" && !($0.title.contains("Settings")) }
            ?? NSApp.windows.first { $0.isVisible && $0.frame.width > 700 }
    }

    private static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
