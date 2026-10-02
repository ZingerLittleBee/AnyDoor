import Foundation
import Testing
import PluginInterface
@testable import AnyDoor

/// `BuiltinGroup` is the single source of truth for command palette grouping.
/// These tests pin disjointness of themed sets, that the themed member sets
/// still equal the command palette's prior hardcoded sets (regression guard so
/// the palette is unchanged), and which items stay in the general Commands
/// section.
struct BuiltinGroupTests {

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

    @Test func defaultOrderMatchesPalette() {
        #expect(BuiltinGroup.themedDefaultOrder == [
            .togglesAppearance, .powerSession, .screenshot, .translation,
        ])
        #expect(BuiltinGroup.screenshot.titleKey == .commandPaletteSectionCapture)
    }

    @Test func appShortcutsWindowLayoutAndHostsStayOutOfThemedGroups() {
        let themed = BuiltinGroup.themedDefaultOrder.reduce(into: Set<BuiltinItem>()) { $0.formUnion($1.members) }
        #expect(!themed.contains(.appShortcuts))
        #expect(!themed.contains(.windowLayout))
        #expect(!themed.contains(.hostsManager))
    }
}
