import AppKit
import PluginInterface
import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class HyperAppShortcutMigrationTests: XCTestCase {
    private let baseFlags = Int(CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue)

    private var shiftedFlags: Int { baseFlags | Int(CGEventFlags.maskShift.rawValue) }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "HyperAppShortcutMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("capsLock", forKey: "hyperKey.trigger")
        defaults.set(true, forKey: "hyperKey.includeShift")
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self, Quicklink.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testChangingShiftMigratesPersistedShortcutsAndLiveDispatchInBothDirections() async throws {
        let defaults = try makeDefaults()
        let container = try makeContainer()
        let context = container.mainContext
        let app = KeyBinding(keyCode: 40, modifierFlags: shiftedFlags,
                             appBundleID: "app", appName: "App", appPath: "/App.app", displayOrder: 200)
        let disabled = KeyBinding(keyCode: 45, modifierFlags: shiftedFlags,
                                  appBundleID: "disabled", appName: "Disabled", appPath: "/Disabled.app",
                                  isEnabled: false, isVisible: false, displayOrder: 100)
        let ordinary = KeyBinding(keyCode: 46, modifierFlags: Int(CGEventFlags.maskCommand.rawValue),
                                  appBundleID: "ordinary", appName: "Ordinary", appPath: "/Ordinary.app")
        for binding in [app, disabled, ordinary] { context.insert(binding) }
        try context.save()

        var snapshots: [HotkeySnapshot] = []
        let coordinator = HotkeyCoordinator(paletteHotkeyResolver: { nil }, snapshotUpdater: { snapshots = $0 })
        coordinator.bootstrap(modelContainer: container, availableCommands: { [] })
        let store = PanelStore()
        store.bootstrap(modelContainer: container, providers: [], refreshHotkeys: { coordinator.refresh() })
        coordinator.refresh()
        let service = HyperKeyService(
            defaults: defaults,
            remapAppShortcuts: { try store.remapHyperAppShortcuts(from: $0, to: $1, paletteHotkey: nil) },
            reportShortcutError: { XCTFail($0) }
        )

        // No live event tap is needed: an inactive Hyper configuration must migrate too.
        XCTAssertFalse(service.isActive)
        await service.setIncludeShift(false)
        XCTAssertFalse(service.includeShift)
        XCTAssertFalse(defaults.bool(forKey: "hyperKey.includeShift"))
        XCTAssertEqual(Set(snapshots), [
            HotkeySnapshot(keyCode: 40, modifierFlags: baseFlags, action: .launchApp(bundleID: "app", path: "/App.app")),
            HotkeySnapshot(keyCode: 46, modifierFlags: ordinary.modifierFlags,
                           action: .launchApp(bundleID: "ordinary", path: "/Ordinary.app"))
        ])
        XCTAssertEqual(store.appShortcutChildren.first { $0.source == .appShortcut(app.id) }?.hotkey,
                       HotkeyDescriptor(keyCode: 40, modifierFlags: baseFlags))
        let saved = try ModelContext(container).fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(saved.first { $0.id == disabled.id }?.modifierFlags, baseFlags)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertFalse(disabled.isVisible)
        XCTAssertEqual(app.displayOrder, 200)
        XCTAssertEqual(disabled.displayOrder, 100)

        await service.setIncludeShift(true)
        XCTAssertTrue(service.includeShift)
        XCTAssertTrue(defaults.bool(forKey: "hyperKey.includeShift"))
        XCTAssertEqual(snapshots.first { $0.action == .launchApp(bundleID: "app", path: "/App.app") }?.modifierFlags,
                       shiftedFlags)
        XCTAssertEqual(disabled.modifierFlags, shiftedFlags)
        XCTAssertEqual(ordinary.modifierFlags, Int(CGEventFlags.maskCommand.rawValue))
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<KeyBinding>())
            .first { $0.id == app.id }?.modifierFlags, shiftedFlags)
    }

    func testConflictRejectsWholeMigrationWithoutChangingSettingsOrDispatch() async throws {
        // Each source enters the real compiler through a different registration path.
        for source in ["app", "builtin", "quicklink", "palette"] {
            let defaults = try makeDefaults()
            let container = try makeContainer()
            let context = container.mainContext
            let first = KeyBinding(keyCode: 40, modifierFlags: shiftedFlags,
                                   appBundleID: "first", appName: "First", appPath: "/First.app")
            let second = KeyBinding(keyCode: 45, modifierFlags: shiftedFlags,
                                    appBundleID: "second", appName: "Second", appPath: "/Second.app")
            context.insert(first)
            context.insert(second)
            let replacement = HotkeyDescriptor(keyCode: 45, modifierFlags: baseFlags)
            var palette: HotkeyDescriptor?
            switch source {
            case "app":
                context.insert(KeyBinding(keyCode: 45, modifierFlags: baseFlags,
                                          appBundleID: "owner", appName: "Owner", appPath: "/Owner.app"))
            case "builtin":
                context.insert(BuiltinPreference(itemKey: BuiltinItem.brightnessUp.rawValue,
                                                 keyCode: 45, modifierFlags: baseFlags))
            case "quicklink":
                context.insert(Quicklink(name: "Link", link: "https://example.com",
                                         keyCode: 45, modifierFlags: baseFlags))
            default:
                palette = replacement
            }
            try context.save()
            let paletteHotkey = palette
            var snapshots: [HotkeySnapshot] = []
            let coordinator = HotkeyCoordinator(paletteHotkeyResolver: { paletteHotkey }, snapshotUpdater: { snapshots = $0 })
            coordinator.bootstrap(modelContainer: container, availableCommands: { [.brightnessUp] })
            let store = PanelStore()
            store.bootstrap(modelContainer: container, providers: [], refreshHotkeys: { coordinator.refresh() })
            coordinator.refresh()
            let previous = Set(snapshots)
            var errors: [String] = []
            let service = HyperKeyService(
                defaults: defaults,
                remapAppShortcuts: {
                    try store.remapHyperAppShortcuts(from: $0, to: $1, paletteHotkey: paletteHotkey)
                },
                reportShortcutError: { errors.append($0) }
            )

            await service.setIncludeShift(false)

            XCTAssertTrue(service.includeShift, source)
            XCTAssertTrue(defaults.bool(forKey: "hyperKey.includeShift"), source)
            XCTAssertEqual(Set(snapshots), previous, source)
            XCTAssertEqual(first.modifierFlags, shiftedFlags, source)
            XCTAssertEqual(second.modifierFlags, shiftedFlags, source)
            XCTAssertEqual(errors.count, 1, "The user must be told why the change was refused: \(source)")
            let saved = try ModelContext(container).fetch(FetchDescriptor<KeyBinding>())
            XCTAssertEqual(saved.first { $0.id == first.id }?.modifierFlags, shiftedFlags, source)
            XCTAssertEqual(saved.first { $0.id == second.id }?.modifierFlags, shiftedFlags, source)
        }
    }
}
