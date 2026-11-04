//
//  HookPresetTests.swift
//  AnyClipTests
//
//  Saving, matching and applying hook presets.
//

import Testing
import Foundation
@testable import AnyClip

@MainActor
struct HookPresetTests {
    private func library() -> HookPresetLibrary {
        let defaults = UserDefaults(suiteName: "anyclip-hookpresets-\(UUID().uuidString)")!
        return HookPresetLibrary(defaults: defaults)
    }

    private var custom: HookStyle {
        var style = HookStyle()
        style.look = .strip
        style.duration = 0
        style.stripColor = "#34C759"
        style.fontName = "Futura"
        style.uppercase = true
        style.positionY = 0.3
        return style
    }

    @Test func aSavedPresetIsKeptForLaterLaunches() {
        let defaults = UserDefaults(suiteName: "anyclip-hookpresets-\(UUID().uuidString)")!
        let preset = HookPresetLibrary(defaults: defaults).save(custom, named: "  My Podcast  ")
        let reopened = HookPresetLibrary(defaults: defaults)
        #expect(reopened.saved.count == 1)
        #expect(reopened.saved.first?.name == "My Podcast")
        #expect(reopened.preset(id: preset?.id ?? "")?.style == custom)
    }

    @Test func savingUnderTheSameNameUpdatesThePreset() {
        let presets = library()
        let first = presets.save(HookStyle(), named: "Podcast")
        let second = presets.save(custom, named: "podcast")
        #expect(presets.saved.count == 1)
        #expect(first?.id == second?.id)
        #expect(presets.saved.first?.style == custom)
        #expect(presets.save(custom, named: "   ") == nil)
    }

    @Test func applyingAPresetKeepsWhetherTheHookIsShown() {
        var hidden = HookStyle()
        hidden.enabled = false
        let applied = hidden.adopting(custom)
        #expect(!applied.enabled)
        #expect(applied.look == .strip && applied.duration == 0 && applied.stripColor == "#34C759")
    }

    @Test func aStyleMatchesItsPresetWhetherOrNotItIsShown() {
        let presets = library()
        let saved = presets.save(custom, named: "Podcast")
        var hidden = custom
        hidden.enabled = false
        #expect(presets.match(hidden)?.id == saved?.id)
        #expect(presets.match(HookStyle())?.id == HookPreset.defaultID)
        var changed = custom
        changed.size += 0.01
        #expect(presets.match(changed) == nil)
    }

    @Test func aNewProjectStartsWithItsPreset() {
        let presets = library()
        let saved = presets.save(custom, named: "Podcast")!
        #expect(presets.style(for: saved.id, shown: true) == custom)
        #expect(presets.style(for: saved.id, shown: false).enabled == false)
        #expect(presets.style(for: HookLook.outline.rawValue, shown: true).look == .outline)
        presets.delete(saved)
        #expect(presets.style(for: saved.id, shown: true) == HookStyle())
    }

    @Test func projectsSavedBeforePresetsUseTheDefault() throws {
        let old = Data(#"{"clipCount":3,"hookEnabled":true}"#.utf8)
        let options = try JSONDecoder().decode(ProjectOptions.self, from: old)
        #expect(options.hookPresetID == HookPreset.defaultID)
    }
}
