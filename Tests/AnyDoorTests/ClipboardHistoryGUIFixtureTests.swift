import Foundation
import ClipboardHistory
import SwiftData
import XCTest

@testable import AnyDoor

@MainActor
final class ClipboardHistoryGUIFixtureTests: XCTestCase {
    func testCreateDisposableLegacyMigrationFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CLIPBOARD_HISTORY_GUI_FIXTURE"] == "1" else {
            throw XCTSkip(
                "Set CLIPBOARD_HISTORY_GUI_FIXTURE=1 with CFFIXED_USER_HOME"
            )
        }
        let fixedHome = try XCTUnwrap(environment["CFFIXED_USER_HOME"])
        let expectedRoot = URL(fileURLWithPath: fixedHome)
            .standardizedFileURL
        let applicationSupport = try XCTUnwrap(
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        )
        XCTAssertTrue(
            applicationSupport.standardizedFileURL.path.hasPrefix(
                expectedRoot.path
            ),
            "The fixture must never use the real user home"
        )
        XCTAssertTrue(
            ClipboardHistoryModule.defaultStoreRoot.standardizedFileURL.path
                .hasPrefix(expectedRoot.path),
            "The v2 store must use the disposable application support root"
        )

        let storeDirectory = applicationSupport.appendingPathComponent(
            "dev.bybee.AnyDoor",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        let storeURL = storeDirectory.appendingPathComponent("AnyDoor.store")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeURL.path),
            "Use a fresh disposable home for every GUI acceptance run"
        )
        let schema = Schema(
            [
                KeyBinding.self,
                BuiltinPreference.self,
                ClipboardHistoryItem.self,
                TranslationRecord.self,
                Quicklink.self,
            ]
                + NativePluginCatalog.modelSchemaTypes
        )
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(url: storeURL)
        )
        container.mainContext.insert(
            KeyBinding(
                keyCode: 122,
                modifierFlags: 0,
                appBundleID: "com.apple.finder",
                appName: "Finder",
                appPath: "/System/Library/CoreServices/Finder.app"
            )
        )
        for index in 0..<160 {
            let marker: String
            switch index % 4 {
            case 0:
                marker = "甲"
            case 1:
                marker = "乙丙"
            case 2:
                marker = "interplanetary-substring"
            default:
                marker = "ordinary"
            }
            let text = "GUI fixture \(index) \(marker)"
            container.mainContext.insert(
                ClipboardHistoryItem(
                    kind: .text,
                    text: text,
                    previewTitle: text,
                    createdAt: Date().addingTimeInterval(
                        TimeInterval(-index)
                    ),
                    sourceBundleID: index.isMultiple(of: 2)
                        ? "com.apple.Safari"
                        : "com.apple.Notes",
                    sourceAppName: index.isMultiple(of: 2)
                        ? "Safari"
                        : "Notes",
                    isFavorite: index.isMultiple(of: 17)
                )
            )
        }
        try container.mainContext.save()
        print("CLIPBOARD_HISTORY_GUI_FIXTURE_ROOT=\(expectedRoot.path)")
    }
}
