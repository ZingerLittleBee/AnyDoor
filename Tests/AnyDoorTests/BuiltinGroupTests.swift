// Tests/AnyDoorTests/BuiltinGroupTests.swift
import Foundation
import Testing
@testable import AnyDoor

/// `BuiltinGroup` is the single source of truth for command grouping, shared by
/// the command palette and the Panel settings page. These tests pin totality
/// (every BuiltinItem maps to exactly one group), disjointness of themed sets,
/// and that the themed member sets still equal the command palette's prior
/// hardcoded sets (regression guard so the palette is unchanged).
struct BuiltinGroupTests {

    @Test func everyItemMapsToExactlyOneGroup() {
        for item in BuiltinItem.allCases {
            let owning = BuiltinGroup.themedDefaultOrder.filter { $0.members.contains(item) }
            #expect(owning.count <= 1, "\(item) is claimed by multiple themed groups: \(owning)")
            let g = BuiltinGroup.group(for: item)
            if owning.isEmpty {
                #expect(g == .general)
            } else {
                #expect(g == owning[0])
            }
        }
    }

    @Test func themedSetsAreDisjoint() {
        var seen = Set<BuiltinItem>()
        for group in BuiltinGroup.themedDefaultOrder {
            for item in group.members {
                #expect(seen.insert(item).inserted, "\(item) appears in more than one themed group")
            }
        }
    }

    @Test func themedMembersMatchCommandPaletteSets() {
        #expect(BuiltinGroup.togglesAppearance.members == [
            .muteAudio, .microphoneMute, .darkMode, .hideDock, .autoHideMenuBar,
            .hideDesktopIcons, .showHiddenFiles, .keyboardLock, .brightness,
        ])
        #expect(BuiltinGroup.powerSession.members == [
            .lockScreen, .displaySleep, .systemSleep, .scheduledShutdown, .keepAwake,
        ])
        #expect(BuiltinGroup.screenshot.members == [
            .screenshot, .captureWindow, .captureFullscreen, .captureTimer,
            .captureModeBar, .recordScreen, .captureScrolling,
        ])
        #expect(BuiltinGroup.translation.members == [
            .translate, .screenshotTranslate, .translateSelection,
        ])
    }

    @Test func defaultOrderMatchesPaletteAndExcludesGeneral() {
        #expect(BuiltinGroup.themedDefaultOrder == [
            .togglesAppearance, .powerSession, .screenshot, .translation,
        ])
        #expect(BuiltinGroup.general.titleKey == nil)
        #expect(BuiltinGroup.screenshot.titleKey == .commandPaletteSectionCapture)
    }

    @Test func appShortcutsAndWindowLayoutFallIntoGeneral() {
        #expect(BuiltinGroup.group(for: .appShortcuts) == .general)
        #expect(BuiltinGroup.group(for: .windowLayout) == .general)
        #expect(BuiltinGroup.group(for: .hostsManager) == .general)
    }
}
