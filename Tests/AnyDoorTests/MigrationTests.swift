import XCTest
import SwiftData
import PluginInterface
@testable import AnyDoor
@testable import HostsPlugin
@testable import ImageConversionPlugin

final class MigrationTests: XCTestCase {
    func testKeyBindingDefaultsWhenInsertedWithoutOrder() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: KeyBinding.self, configurations: config)
        let context = ModelContext(container)

        let binding = KeyBinding(
            keyCode: 122, // F1
            modifierFlags: 0,
            appBundleID: "com.apple.Safari",
            appName: "Safari",
            appPath: "/Applications/Safari.app"
        )
        context.insert(binding)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertTrue(fetched[0].isVisible)
        XCTAssertEqual(fetched[0].displayOrder, 0)
    }

    @MainActor
    func testAddingQuicklinkModelPreservesExistingStoreRows() throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyDoorMigration-\(UUID().uuidString).store")
        defer { removeStoreFiles(at: storeURL) }

        do {
            let oldSchema = Schema([
                KeyBinding.self,
                BuiltinPreference.self,
                HostProfile.self,
                TranslationRecord.self,
                ImageConversionRecord.self,
            ])
            let container = try ModelContainer(
                for: oldSchema,
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = container.mainContext
            context.insert(KeyBinding(
                keyCode: 122,
                modifierFlags: 0,
                appBundleID: "com.apple.finder",
                appName: "Finder",
                appPath: "/System/Library/CoreServices/Finder.app"
            ))
            try context.save()
        }

        do {
            let newSchema = Schema([
                KeyBinding.self,
                BuiltinPreference.self,
                HostProfile.self,
                TranslationRecord.self,
                ImageConversionRecord.self,
                Quicklink.self,
            ])
            let container = try ModelContainer(
                for: newSchema,
                configurations: [ModelConfiguration(url: storeURL)]
            )
            let context = container.mainContext

            let bindings = try context.fetch(FetchDescriptor<KeyBinding>())
            XCTAssertEqual(bindings.map(\.appBundleID), ["com.apple.finder"])
            XCTAssertTrue(try context.fetch(FetchDescriptor<Quicklink>()).isEmpty)

            context.insert(Quicklink(name: "AnyDoor", link: "~/Bee/AnyDoor"))
            try context.save()
            XCTAssertEqual(try context.fetch(FetchDescriptor<Quicklink>()).count, 1)
        }
    }

    private func removeStoreFiles(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

final class BuiltinItemTests: XCTestCase {
    func testAllCasesHaveDistinctOrder() {
        let orders = BuiltinItem.allCases.map(\.defaultOrder)
        XCTAssertEqual(Set(orders).count, orders.count)
    }

    func testAppShortcutsIsSubmenu() {
        XCTAssertEqual(BuiltinItem.appShortcuts.kind, .submenu)
    }

    func testAutomationItemsAreFlagged() {
        XCTAssertTrue(BuiltinItem.darkMode.requiresAutomation)
        XCTAssertTrue(BuiltinItem.emptyTrash.requiresAutomation)
        XCTAssertFalse(BuiltinItem.keepAwake.requiresAutomation)
    }

    func testOCRIsAnActionItem() {
        XCTAssertEqual(BuiltinItem.ocr.kind, .action)
    }

    func testOCRMetadata() {
        XCTAssertEqual(BuiltinItem.ocr.titleKey, .builtinOCR)
        XCTAssertEqual(BuiltinItem.ocr.symbol, "text.viewfinder")
        XCTAssertEqual(BuiltinItem.ocr.defaultOrder, 950)
        XCTAssertFalse(BuiltinItem.ocr.requiresAutomation)
        XCTAssertNil(BuiltinItem.ocr.feedbackSound)
    }

    func testPickColorIsAnActionItem() {
        XCTAssertEqual(BuiltinItem.pickColor.kind, .action)
    }

    func testPickColorMetadata() {
        XCTAssertEqual(BuiltinItem.pickColor.titleKey, .builtinPickColor)
        XCTAssertEqual(BuiltinItem.pickColor.symbol, "eyedropper")
        XCTAssertEqual(BuiltinItem.pickColor.defaultOrder, 975)
        XCTAssertFalse(BuiltinItem.pickColor.requiresAutomation)
        XCTAssertNil(BuiltinItem.pickColor.feedbackSound)
    }

    func testQRCodeItem() {
        XCTAssertEqual(BuiltinItem.qrcode.kind, .action)
        XCTAssertEqual(BuiltinItem.qrcode.titleKey, .builtinQRCode)
        XCTAssertEqual(BuiltinItem.qrcode.symbol, "qrcode.viewfinder")
        XCTAssertEqual(BuiltinItem.qrcode.defaultOrder, 960)
        XCTAssertFalse(BuiltinItem.qrcode.requiresAutomation)
        XCTAssertNil(BuiltinItem.qrcode.feedbackSound)
    }

    func testHistoryKinds() {
        XCTAssertEqual(BuiltinItem.ocr.historyKind, .ocr)
        XCTAssertEqual(BuiltinItem.pickColor.historyKind, .color)
        XCTAssertEqual(BuiltinItem.qrcode.historyKind, .qrcode)
        XCTAssertEqual(BuiltinItem.screenshot.historyKind, .screenshot)
        XCTAssertNil(BuiltinItem.keepAwake.historyKind)
        XCTAssertNil(BuiltinItem.portManager.historyKind)
    }

    func testHistoryCapableItemsRemainActions() {
        XCTAssertEqual(BuiltinItem.ocr.kind, .action)
        XCTAssertEqual(BuiltinItem.pickColor.kind, .action)
        XCTAssertEqual(BuiltinItem.qrcode.kind, .action)
        XCTAssertEqual(BuiltinItem.screenshot.kind, .action)
    }
}

final class KeyBindingOrderBackfillTests: XCTestCase {
    @MainActor
    func testBackfillAssignsAscendingOrderByCreatedAt() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: KeyBinding.self, configurations: config)
        let context = ModelContext(container)

        let a = KeyBinding(keyCode: 122, modifierFlags: 0,
                           appBundleID: "a", appName: "A", appPath: "/a")
        let b = KeyBinding(keyCode: 120, modifierFlags: 0,
                           appBundleID: "b", appName: "B", appPath: "/b")
        a.createdAt = Date(timeIntervalSinceReferenceDate: 0)
        b.createdAt = Date(timeIntervalSinceReferenceDate: 10)
        context.insert(a)
        context.insert(b)
        try context.save()

        KeyBindingOrderBackfill.runIfNeeded(in: context)

        let rows = try context.fetch(FetchDescriptor<KeyBinding>(
            sortBy: [SortDescriptor(\.displayOrder)]
        ))
        XCTAssertEqual(rows[0].appBundleID, "a")
        XCTAssertEqual(rows[1].appBundleID, "b")
        XCTAssertLessThan(rows[0].displayOrder, rows[1].displayOrder)
    }

    @MainActor
    func testBackfillIsNoOpIfAlreadyDone() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: KeyBinding.self, configurations: config)
        let context = ModelContext(container)

        let a = KeyBinding(keyCode: 122, modifierFlags: 0,
                           appBundleID: "a", appName: "A", appPath: "/a",
                           displayOrder: 500)
        context.insert(a)
        try context.save()

        KeyBindingOrderBackfill.runIfNeeded(in: context)

        let rows = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(rows[0].displayOrder, 500)
    }
}
