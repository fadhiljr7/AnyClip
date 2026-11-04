//
//  HookPreset.swift
//  AnyClip
//
//  Named hook styles to reuse across clips and new projects: the four built-in
//  looks plus the ones people save from the editor's Hook tab.
//

import Foundation
import Observation

/// A hook style with a name: timing, look, colours and text settings. A clip's hook words and whether its hook is
/// shown belong to the clip, so a preset never changes them.
nonisolated struct HookPreset: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var style: HookStyle

    /// Each look with its standard settings, always available and never changed.
    static let builtIn: [HookPreset] = HookLook.allCases.map { look in
        var style = HookStyle()
        style.look = look
        return HookPreset(id: look.rawValue, name: look.name, style: style)
    }

    static let defaultID = HookLook.card.rawValue

    var isBuiltIn: Bool { HookLook(rawValue: id) != nil }
}

nonisolated extension HookStyle {
    /// This clip's style with another's look and timing; the clip keeps whether its hook is shown.
    func adopting(_ other: HookStyle) -> HookStyle {
        var style = other
        style.enabled = enabled
        return style
    }

    /// Whether two styles look and time the same, whether or not the hook is shown.
    func matches(_ other: HookStyle) -> Bool {
        adopting(other) == self
    }
}

/// The presets someone saved, kept in their preferences so every project can use them.
@Observable
final class HookPresetLibrary {
    static let shared = HookPresetLibrary()

    private(set) var saved: [HookPreset]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saved = defaults.data(forKey: AppSettings.Key.hookPresets)
            .flatMap { try? JSONDecoder().decode([HookPreset].self, from: $0) } ?? []
    }

    var all: [HookPreset] { HookPreset.builtIn + saved }

    func preset(id: String) -> HookPreset? { all.first { $0.id == id } }

    /// The preset a style matches, if any; a saved one wins over a built-in look with the same settings.
    func match(_ style: HookStyle) -> HookPreset? {
        (saved.reversed() + HookPreset.builtIn).first { style.matches($0.style) }
    }

    /// The style a new project's clips start with. A preset deleted since the project was set up falls back to the default.
    func style(for id: String, shown: Bool) -> HookStyle {
        var style = preset(id: id)?.style ?? HookStyle()
        style.enabled = shown
        return style
    }

    /// Saves a style under a name. Saving under the name of a saved preset updates that preset.
    @discardableResult
    func save(_ style: HookStyle, named name: String) -> HookPreset? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var style = style
        style.enabled = true
        let preset: HookPreset
        if let i = saved.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            saved[i].name = name
            saved[i].style = style
            preset = saved[i]
        } else {
            preset = HookPreset(id: UUID().uuidString, name: name, style: style)
            saved.append(preset)
        }
        persist()
        return preset
    }

    func rename(_ preset: HookPreset, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = saved.firstIndex(where: { $0.id == preset.id }) else { return }
        saved[i].name = name
        persist()
    }

    func delete(_ preset: HookPreset) {
        saved.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(saved), forKey: AppSettings.Key.hookPresets)
    }
}
