import CoreGraphics
import XCTest
@testable import AnyDoor

final class HotkeyCoordinatorTests: XCTestCase {

    private let command = Int(CGEventFlags.maskCommand.rawValue)
    private let control = Int(CGEventFlags.maskControl.rawValue)
    private let option = Int(CGEventFlags.maskAlternate.rawValue)

    private func makeBinding(keyCode: Int = 1, modifierFlags: Int? = nil) -> KeyBinding {
        KeyBinding(
            keyCode: keyCode,
            modifierFlags: modifierFlags ?? command,
            appBundleID: "com.example.app",
            appName: "Example",
            appPath: "/Applications/Example.app",
            isEnabled: true,
            isVisible: true,
            displayOrder: 100
        )
    }

    @MainActor
    func testAppShortcutCompilesToLaunchApp() {
        let snapshots = HotkeyCoordinator.compile(
            bindings: [makeBinding(keyCode: 11, modifierFlags: control)],
            prefs: [],
            quicklinks: [],
            paletteHotkey: nil
        )
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].keyCode, 11)
        XCTAssertEqual(snapshots[0].modifierFlags, control)
        guard case .launchApp(let bundleID, let path) = snapshots[0].action else {
            return XCTFail("expected launchApp, got \(snapshots[0].action)")
        }
        XCTAssertEqual(bundleID, "com.example.app")
        XCTAssertEqual(path, "/Applications/Example.app")
    }

    @MainActor
    func testToggleBuiltinCompilesToToggleAction() {
        let pref = BuiltinPreference(
            itemKey: BuiltinItem.keepAwake.rawValue,
            keyCode: 2,
            modifierFlags: command
        )
        let snapshots = HotkeyCoordinator.compile(bindings: [], prefs: [pref], quicklinks: [], paletteHotkey: nil)
        XCTAssertEqual(snapshots.count, 1)
        guard case .toggleBuiltin(let key) = snapshots[0].action else {
            return XCTFail("expected toggleBuiltin, got \(snapshots[0].action)")
        }
        XCTAssertEqual(key, BuiltinItem.keepAwake.rawValue)
    }

    @MainActor
    func testActionBuiltinCompilesToRunAction() {
        let pref = BuiltinPreference(
            itemKey: BuiltinItem.lockScreen.rawValue,
            keyCode: 3,
            modifierFlags: command
        )
        let snapshots = HotkeyCoordinator.compile(bindings: [], prefs: [pref], quicklinks: [], paletteHotkey: nil)
        XCTAssertEqual(snapshots.count, 1)
        guard case .runBuiltin(let key) = snapshots[0].action else {
            return XCTFail("expected runBuiltin, got \(snapshots[0].action)")
        }
        XCTAssertEqual(key, BuiltinItem.lockScreen.rawValue)
    }

    @MainActor
    func testHiddenHotkeyItemsCompileToBrightnessActions() {
        let up = BuiltinPreference(
            itemKey: BuiltinItem.brightnessUp.rawValue,
            keyCode: 4,
            modifierFlags: command
        )
        let down = BuiltinPreference(
            itemKey: BuiltinItem.brightnessDown.rawValue,
            keyCode: 5,
            modifierFlags: command
        )
        let snapshots = HotkeyCoordinator.compile(bindings: [], prefs: [up, down], quicklinks: [], paletteHotkey: nil)
        XCTAssertEqual(snapshots.map(\.action), [.brightnessUp, .brightnessDown])
    }

    @MainActor
    func testSubmenuAndBrightnessControlAreSkipped() {
        let submenu = BuiltinPreference(
            itemKey: BuiltinItem.appShortcuts.rawValue,
            keyCode: 6,
            modifierFlags: command
        )
        let control = BuiltinPreference(
            itemKey: BuiltinItem.brightness.rawValue,
            keyCode: 7,
            modifierFlags: command
        )
        let snapshots = HotkeyCoordinator.compile(
            bindings: [],
            prefs: [submenu, control],
            quicklinks: [],
            paletteHotkey: nil
        )
        XCTAssertTrue(snapshots.isEmpty)
    }

    @MainActor
    func testPrefWithoutHotkeyIsSkipped() {
        let pref = BuiltinPreference(itemKey: BuiltinItem.keepAwake.rawValue)
        let snapshots = HotkeyCoordinator.compile(bindings: [], prefs: [pref], quicklinks: [], paletteHotkey: nil)
        XCTAssertTrue(snapshots.isEmpty)
    }

    @MainActor
    func testOrphanPrefKeyIsSkipped() {
        let pref = BuiltinPreference(itemKey: "noSuchBuiltin", keyCode: 8, modifierFlags: command)
        let snapshots = HotkeyCoordinator.compile(bindings: [], prefs: [pref], quicklinks: [], paletteHotkey: nil)
        XCTAssertTrue(snapshots.isEmpty)
    }

    @MainActor
    func testPaletteHotkeyIsAppended() {
        let descriptor = HotkeyDescriptor(keyCode: 49, modifierFlags: command)
        let snapshots = HotkeyCoordinator.compile(
            bindings: [makeBinding()],
            prefs: [],
            quicklinks: [],
            paletteHotkey: descriptor
        )
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[1].keyCode, 49)
        XCTAssertEqual(snapshots[1].action, .showCommandPalette)
    }

    @MainActor
    func testQuicklinkHotkeyCompilesEvenWhenHidden() {
        let hidden = Quicklink(
            id: UUID(),
            name: "Hidden",
            link: "https://example.com",
            keyCode: 5,
            modifierFlags: control | option | command,
            isVisible: false
        )
        let unbound = Quicklink(
            id: UUID(),
            name: "Unbound",
            link: "https://example.com/unbound",
            isVisible: true
        )

        let snapshots = HotkeyCoordinator.compile(
            bindings: [],
            prefs: [],
            quicklinks: [hidden, unbound],
            paletteHotkey: nil
        )

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].keyCode, 5)
        XCTAssertEqual(snapshots[0].modifierFlags, control | option | command)
        XCTAssertEqual(snapshots[0].action, .openQuicklink(id: hidden.id))
    }

    @MainActor
    func testDispatchPlainQuicklinkOpensDirectly() {
        let quicklink = Quicklink(id: UUID(), name: "Docs", link: "https://example.com")
        var openedID: UUID?
        var presentedID: UUID?
        let coordinator = HotkeyCoordinator(
            quicklinkResolver: { id in id == quicklink.id ? quicklink : nil },
            quicklinkOpener: { openedID = $0.id },
            quicklinkArgumentPresenter: { quicklinkID, _, _ in presentedID = quicklinkID }
        )

        coordinator.dispatch(.openQuicklink(id: quicklink.id))

        XCTAssertEqual(openedID, quicklink.id)
        XCTAssertNil(presentedID)
    }

    @MainActor
    func testDispatchTemplateQuicklinkShowsArgumentInput() {
        let quicklink = Quicklink(
            id: UUID(),
            name: "GitHub 搜索",
            link: "https://github.com/search?q={query}"
        )
        var openedID: UUID?
        var presented: (id: UUID, title: String, link: String)?
        let coordinator = HotkeyCoordinator(
            quicklinkResolver: { id in id == quicklink.id ? quicklink : nil },
            quicklinkOpener: { openedID = $0.id },
            quicklinkArgumentPresenter: { quicklinkID, title, link in
                presented = (quicklinkID, title, link)
            }
        )

        coordinator.dispatch(.openQuicklink(id: quicklink.id))

        XCTAssertNil(openedID)
        XCTAssertEqual(presented?.id, quicklink.id)
        XCTAssertEqual(presented?.title, "GitHub 搜索")
        XCTAssertEqual(presented?.link, "https://github.com/search?q={query}")
    }
}
