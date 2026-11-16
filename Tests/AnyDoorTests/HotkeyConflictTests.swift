import CoreGraphics
import PluginInterface
import SwiftData
import XCTest
@testable import AnyDoor

final class HotkeyConflictTests: XCTestCase {
    private let command = Int(CGEventFlags.maskCommand.rawValue)
    private let option = Int(CGEventFlags.maskAlternate.rawValue)
    private let shift = Int(CGEventFlags.maskShift.rawValue)

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self, Quicklink.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testMatchByKeyCodeAndModifiers() {
        let snapshots: [HotkeySnapshot] = [
            HotkeySnapshot(keyCode: 122, modifierFlags: 0,
                           action: .launchApp(bundleID: "a", path: "/a")),
            HotkeySnapshot(keyCode: 120, modifierFlags: 256,
                           action: .toggleBuiltin(itemKey: "keepAwake")),
        ]

        let hit = snapshots.first { $0.keyCode == 120 && $0.modifierFlags == 256 }
        XCTAssertNotNil(hit)
        if case let .toggleBuiltin(key) = hit?.action {
            XCTAssertEqual(key, "keepAwake")
        } else {
            XCTFail("wrong action type")
        }
    }

    func testConflictDetectionAcrossLaunchAndBuiltin() {
        let a = HotkeySnapshot(keyCode: 122, modifierFlags: 0,
                               action: .launchApp(bundleID: "a", path: "/a"))
        let b = HotkeySnapshot(keyCode: 122, modifierFlags: 0,
                               action: .toggleBuiltin(itemKey: "keepAwake"))

        XCTAssertEqual(a.keyCode, b.keyCode)
        XCTAssertEqual(a.modifierFlags, b.modifierFlags)
        XCTAssertNotEqual(a, b)
    }

    @MainActor
    func testAppShortcutDetectsConflictsAcrossAllActiveHotkeySources() throws {
        let container = try makeContainer()
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let store = PanelStore()
        store.bootstrap(modelContainer: container, providers: [])
        let quicklinks = QuicklinkStore(modelContext: container.mainContext, refreshHotkeys: {})

        let existingAppID = try XCTUnwrap(store.addAppShortcut(
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            appPath: "/Applications/Safari.app"
        ))
        let newAppID = try XCTUnwrap(store.addAppShortcut(
            appBundleID: "com.tencent.xinWeChat",
            appName: "WeChat",
            appPath: "/Applications/WeChat.app"
        ))

        let appCombo = HotkeyDescriptor(keyCode: 1, modifierFlags: command | option)
        let builtinCombo = HotkeyDescriptor(keyCode: 9, modifierFlags: command | shift)
        let windowCombo = HotkeyDescriptor(keyCode: 37, modifierFlags: command | option)
        let brightnessCombo = HotkeyDescriptor(keyCode: 126, modifierFlags: command | option)
        let quicklinkCombo = HotkeyDescriptor(keyCode: 5, modifierFlags: command | option)
        let paletteCombo = HotkeyDescriptor(keyCode: 49, modifierFlags: option)

        store.updateAppShortcut(id: existingAppID, hotkey: appCombo)
        store.setBuiltinHotkey(.clipboardWall, hotkey: builtinCombo)
        store.setBuiltinHotkey(.windowLeftHalf, hotkey: windowCombo)
        store.setBuiltinHotkey(.brightnessUp, hotkey: brightnessCombo)
        let hiddenQuicklink = try quicklinks.add(
            name: "GitHub",
            link: "https://github.com",
            hotkey: quicklinkCombo,
            isVisible: false
        )

        XCTAssertEqual(
            store.hotkeyConflict(for: appCombo, excluding: .appShortcut(newAppID), paletteHotkey: paletteCombo),
            .appShortcut(id: existingAppID, appName: "Safari")
        )
        XCTAssertNil(
            store.hotkeyConflict(for: appCombo, excluding: .appShortcut(existingAppID), paletteHotkey: paletteCombo),
            "re-recording the same shortcut on its current owner must not report a self-conflict"
        )
        XCTAssertEqual(
            store.hotkeyConflict(for: builtinCombo, excluding: .appShortcut(newAppID), paletteHotkey: paletteCombo),
            .builtin(.clipboardWall)
        )
        XCTAssertEqual(
            store.hotkeyConflict(for: windowCombo, excluding: .appShortcut(newAppID), paletteHotkey: paletteCombo),
            .builtin(.windowLeftHalf)
        )
        XCTAssertEqual(
            store.hotkeyConflict(for: brightnessCombo, excluding: .appShortcut(newAppID), paletteHotkey: paletteCombo),
            .builtin(.brightnessUp)
        )
        XCTAssertEqual(
            store.hotkeyConflict(for: quicklinkCombo, excluding: .appShortcut(newAppID), paletteHotkey: paletteCombo),
            .quicklink(id: hiddenQuicklink.id, title: "GitHub"),
            "hidden quicklinks still fire global hotkeys and must participate in conflict checks"
        )
        XCTAssertEqual(
            store.hotkeyConflict(for: paletteCombo, excluding: .appShortcut(newAppID), paletteHotkey: paletteCombo),
            .commandPalette
        )
        XCTAssertNil(
            store.hotkeyConflict(for: paletteCombo, excluding: .commandPalette, paletteHotkey: paletteCombo)
        )
    }

    @MainActor
    func testUninstalledPluginRetainedHotkeyDoesNotBlockAppShortcut() throws {
        let container = try makeContainer()
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let retainedCombo = HotkeyDescriptor(keyCode: 34, modifierFlags: command | shift)

        let availableStore = PanelStore()
        availableStore.bootstrap(modelContainer: container, providers: [])
        availableStore.setBuiltinHotkey(.imageConversion, hotkey: retainedCombo)

        let uninstalledStore = PanelStore()
        uninstalledStore.bootstrap(
            modelContainer: container,
            providers: [],
            commandAvailability: { $0 != .imageConversion }
        )
        let appID = try XCTUnwrap(uninstalledStore.addAppShortcut(
            appBundleID: "com.apple.Notes",
            appName: "Notes",
            appPath: "/System/Applications/Notes.app"
        ))

        XCTAssertNil(
            uninstalledStore.hotkeyConflict(
                for: retainedCombo,
                excluding: .appShortcut(appID),
                paletteHotkey: nil
            )
        )
    }

    @MainActor
    func testReplacingConflictingAppShortcutClearsPreviousBindingAndDisablesIt() throws {
        let container = try makeContainer()
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let store = PanelStore()
        store.bootstrap(modelContainer: container, providers: [])
        let quicklinks = QuicklinkStore(modelContext: container.mainContext, refreshHotkeys: {})

        let firstAppID = try XCTUnwrap(store.addAppShortcut(
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            appPath: "/Applications/Safari.app"
        ))
        let secondAppID = try XCTUnwrap(store.addAppShortcut(
            appBundleID: "com.apple.Terminal",
            appName: "Terminal",
            appPath: "/System/Applications/Utilities/Terminal.app"
        ))
        let combo = HotkeyDescriptor(keyCode: 17, modifierFlags: command | option)
        store.updateAppShortcut(id: firstAppID, hotkey: combo)

        let conflict = try XCTUnwrap(
            store.hotkeyConflict(for: combo, excluding: .appShortcut(secondAppID), paletteHotkey: nil)
        )
        XCTAssertEqual(conflict, .appShortcut(id: firstAppID, appName: "Safari"))
        XCTAssertEqual(conflict.localizedTitle, "Safari")

        store.clearConflictingHotkey(
            conflict.target,
            clearQuicklink: { quicklinks.clearHotkey(id: $0) },
            clearPaletteHotkey: {}
        )
        store.updateAppShortcut(id: secondAppID, hotkey: combo)

        let firstBinding = try XCTUnwrap(store.binding(id: firstAppID))
        XCTAssertEqual(firstBinding.keyCode, -1)
        XCTAssertEqual(firstBinding.modifierFlags, 0)
        XCTAssertFalse(firstBinding.isEnabled)
        XCTAssertNil(
            store.appShortcutChildren.first { $0.source == .appShortcut(firstAppID) }?.hotkey
        )
        XCTAssertEqual(
            store.appShortcutChildren.first { $0.source == .appShortcut(secondAppID) }?.hotkey,
            combo
        )

        let enabledBindings = try container.mainContext.fetch(
            FetchDescriptor<KeyBinding>(predicate: #Predicate { $0.isEnabled })
        )
        let snapshots = HotkeyCoordinator.compile(
            bindings: enabledBindings,
            prefs: [],
            quicklinks: [],
            paletteHotkey: nil
        )
        XCTAssertEqual(
            snapshots,
            [HotkeySnapshot(
                keyCode: combo.keyCode,
                modifierFlags: combo.modifierFlags,
                action: .launchApp(
                    bundleID: "com.apple.Terminal",
                    path: "/System/Applications/Utilities/Terminal.app"
                )
            )]
        )
    }

    @MainActor
    func testClearConflictingHotkeyClearsBuiltinQuicklinkAndCommandPalette() throws {
        let container = try makeContainer()
        BuiltinPreferenceSeeder.seedIfNeeded(in: container.mainContext)
        let store = PanelStore()
        store.bootstrap(modelContainer: container, providers: [])
        let quicklinks = QuicklinkStore(modelContext: container.mainContext, refreshHotkeys: {})

        let builtinCombo = HotkeyDescriptor(keyCode: 8, modifierFlags: command | shift)
        let quicklinkCombo = HotkeyDescriptor(keyCode: 15, modifierFlags: command | option)
        var paletteHotkey: HotkeyDescriptor? = HotkeyDescriptor(keyCode: 49, modifierFlags: option)

        store.setBuiltinHotkey(.screenshot, hotkey: builtinCombo)
        let quicklink = try quicklinks.add(
            name: "Docs",
            link: "https://example.com/docs",
            hotkey: quicklinkCombo
        )

        let builtinConflict = try XCTUnwrap(
            store.hotkeyConflict(for: builtinCombo, paletteHotkey: paletteHotkey)
        )
        XCTAssertFalse(builtinConflict.localizedTitle.isEmpty)
        store.clearConflictingHotkey(
            builtinConflict.target,
            clearQuicklink: { quicklinks.clearHotkey(id: $0) },
            clearPaletteHotkey: { paletteHotkey = nil }
        )
        XCTAssertNil(store.hotkeyForBuiltin(.screenshot))

        let quicklinkConflict = try XCTUnwrap(
            store.hotkeyConflict(for: quicklinkCombo, paletteHotkey: paletteHotkey)
        )
        XCTAssertEqual(quicklinkConflict.localizedTitle, "Docs")
        store.clearConflictingHotkey(
            quicklinkConflict.target,
            clearQuicklink: { quicklinks.clearHotkey(id: $0) },
            clearPaletteHotkey: { paletteHotkey = nil }
        )
        XCTAssertNil(quicklinks.quicklink(id: quicklink.id)?.hotkeyDescriptor)

        let paletteConflict = try XCTUnwrap(
            store.hotkeyConflict(
                for: HotkeyDescriptor(keyCode: 49, modifierFlags: option),
                paletteHotkey: paletteHotkey
            )
        )
        XCTAssertFalse(paletteConflict.localizedTitle.isEmpty)
        store.clearConflictingHotkey(
            paletteConflict.target,
            clearQuicklink: { quicklinks.clearHotkey(id: $0) },
            clearPaletteHotkey: { paletteHotkey = nil }
        )
        XCTAssertNil(paletteHotkey)
    }

    @MainActor
    func testAddAppShortcutDeduplicatesExistingBundleID() throws {
        let container = try makeContainer()
        let store = PanelStore()
        store.bootstrap(modelContainer: container, providers: [])

        let first = try XCTUnwrap(store.addAppShortcut(
            appBundleID: "com.apple.Calculator",
            appName: "Calculator",
            appPath: "/System/Applications/Calculator.app"
        ))
        let second = try XCTUnwrap(store.addAppShortcut(
            appBundleID: "com.apple.Calculator",
            appName: "Calculator",
            appPath: "/System/Applications/Calculator.app"
        ))

        XCTAssertEqual(first, second)
        XCTAssertEqual(store.appShortcutChildren.count, 1)
    }
}
