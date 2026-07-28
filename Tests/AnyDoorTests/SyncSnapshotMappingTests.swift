import XCTest
@testable import AnyDoor

final class SyncSnapshotMappingTests: XCTestCase {

    private func sampleContent() -> SyncSnapshotMapping.Content {
        SyncSnapshotMapping.Content(
            appShortcuts: [
                AppShortcutDTO(appBundleID: "com.apple.Safari", appName: "Safari",
                               keyCode: 4, modifierFlags: 256,
                               isEnabled: true, isVisible: true, displayOrder: 100),
                AppShortcutDTO(appBundleID: "com.apple.Terminal", appName: "Terminal",
                               keyCode: 17, modifierFlags: 768,
                               isEnabled: false, isVisible: true, displayOrder: 200),
            ],
            builtinPreferences: [
                BuiltinPreferenceDTO(itemKey: "clipboardWall", isVisible: true,
                                     displayOrder: 100, keyCode: 9, modifierFlags: 256),
                BuiltinPreferenceDTO(itemKey: "keepAwake", isVisible: false,
                                     displayOrder: 300, keyCode: nil, modifierFlags: nil),
            ],
            quicklinks: [
                QuicklinkDTO(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    name: "GitHub", keyword: "gh",
                    link: "https://github.com/search?q={query}",
                    openWithBundleID: nil, keyCode: nil, modifierFlags: nil,
                    isVisible: true, displayOrder: 100,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
            ],
            settings: [
                "menuBar.iconVisible": .bool(true),
                "clipboard.excludedBundleIDs": .stringArray(["com.1password.1password"]),
            ]
        )
    }

    func testContentRoundTripsThroughPayloads() {
        let content = sampleContent()
        let payloads = SyncSnapshotMapping.payloads(from: content)
        let clock = SyncTimestamp(wallMillis: 1, counter: 0, deviceID: "a")
        let entries = payloads.mapValues { SyncEntry(payload: $0, clock: clock) }
        XCTAssertEqual(SyncSnapshotMapping.content(from: entries), content)
    }

    func testTombstonesAndKindMismatchesAreSkipped() {
        let clock = SyncTimestamp(wallMillis: 1, counter: 0, deviceID: "a")
        let entries: [SyncKey: SyncEntry] = [
            .setting(key: "gone"): SyncEntry(payload: nil, clock: clock),
            // A quicklink key carrying a setting payload is corrupt.
            .quicklink(id: UUID()): SyncEntry(payload: .setting(.int(1)), clock: clock),
            .setting(key: "kept"): SyncEntry(payload: .setting(.bool(true)), clock: clock),
        ]
        let content = SyncSnapshotMapping.content(from: entries)
        XCTAssertEqual(content.settings, ["kept": .bool(true)])
        XCTAssertTrue(content.quicklinks.isEmpty)
    }

    func testKeyIdentityOverridesPayloadIdentity() {
        let clock = SyncTimestamp(wallMillis: 1, counter: 0, deviceID: "a")
        var dto = sampleContent().appShortcuts[0]
        dto.appBundleID = "com.evil.Impostor"
        let entries: [SyncKey: SyncEntry] = [
            .appShortcut(bundleID: "com.apple.Safari"):
                SyncEntry(payload: .appShortcut(dto), clock: clock)
        ]
        let content = SyncSnapshotMapping.content(from: entries)
        XCTAssertEqual(content.appShortcuts.map(\.appBundleID), ["com.apple.Safari"])
    }

    func testLaterDuplicateWinsWhenBuildingPayloads() {
        var content = sampleContent()
        var duplicate = content.appShortcuts[0]
        duplicate.appName = "Safari (renamed)"
        content.appShortcuts.append(duplicate)
        let payloads = SyncSnapshotMapping.payloads(from: content)
        guard case .appShortcut(let winner)? =
                payloads[.appShortcut(bundleID: "com.apple.Safari")] else {
            return XCTFail("missing app shortcut payload")
        }
        XCTAssertEqual(winner.appName, "Safari (renamed)")
    }
}
