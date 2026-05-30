# Config Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users back up and restore their AnyDoor configuration (app shortcuts, builtin preferences, whitelisted general settings) to/from a local JSON file, behind a pluggable backend abstraction so iCloud/Gist/S3 can be added later.

**Architecture:** A Codable `BackupSnapshot` is the portable representation. `BackupService` (@MainActor) reads local state into a snapshot (export) and merges a snapshot back into local state (import). `BackupCodec` serializes snapshot ↔ JSON `Data`. A `SyncBackend` protocol moves the bytes; the first implementation is `LocalFileBackend(url:)`, with the UI obtaining the URL via NSSavePanel/NSOpenPanel. A new "同步" tab in `SettingsView` drives export/import.

**Tech Stack:** Swift 6.2 (strict concurrency, `.v6` mode), SwiftData, SwiftUI, XCTest, in-memory `ModelContainer` for tests, `Localizable.xcstrings` string catalog.

---

## Design Decisions (read before starting)

- **Merge identity keys:** app shortcuts merge by `appBundleID`; builtin preferences merge by `itemKey`. Import wins per key; local-only rows are never deleted.
- **No `appPath` in the snapshot.** Absolute paths embed the username/install location and differ across machines. On import the path is re-resolved locally from the bundle ID via `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`. A binding whose app is not installed is still imported with an empty path.
- **UserDefaults whitelist** lives in `SyncSettingsRegistry`. Machine-specific keys (`hyperKey.ownedSignatures`, `PortInventory.viewMode`, `SUSkippedVersion`) are excluded.
- **Service reconcile after import.** Writing `UserDefaults` directly bypasses service setters that carry side effects (registering hotkeys, applying the HID mapping, refreshing localized state). `BackupService` writes the raw values during merge; the caller (the view) then calls `BackupService.reconcileAfterImport()` plus `PanelStore.shared.rebuild()` / `rebuildHotkeySnapshots()`.
- **Why `BackupService` writes the SwiftData context directly** instead of routing through `PanelStore` mutation methods: a batch import would otherwise trigger N saves/rebuilds and the existing methods can't insert a new app shortcut with a specific hotkey. The CLAUDE.md guideline's purpose (save + rebuild + hotkey-snapshot rebuild) is honored by doing those once after the batch, in the caller.

## File Structure

**Create:**
- `Sources/AnyDoor/Models/BackupSnapshot.swift` — `BackupSnapshot`, `AppShortcutDTO`, `BuiltinPreferenceDTO`, `SettingValue`. Pure Codable value types.
- `Sources/AnyDoor/Services/SyncSettingsRegistry.swift` — UserDefaults whitelist + typed read/write helpers.
- `Sources/AnyDoor/Services/BackupCodec.swift` — `BackupSnapshot` ↔ `Data` (JSON), schemaVersion validation.
- `Sources/AnyDoor/Services/SyncBackend.swift` — `SyncBackend` protocol + `LocalFileBackend`.
- `Sources/AnyDoor/Services/BackupService.swift` — `BackupService` (@MainActor) + `ImportSummary`.
- `Sources/AnyDoor/Views/SyncSettingsView.swift` — the "同步" settings tab.
- `Tests/AnyDoorTests/BackupCodecTests.swift`
- `Tests/AnyDoorTests/SyncSettingsRegistryTests.swift`
- `Tests/AnyDoorTests/BackupServiceTests.swift`

**Modify:**
- `Sources/AnyDoor/Utilities/L10n.swift` — add `L10n.Key` cases (alphabetical by raw value).
- `Sources/AnyDoor/Resources/Localizable.xcstrings` — add catalog entries for the new keys.
- `Sources/AnyDoor/Views/SettingsView.swift` — add the third tab.

---

## Task 1: `BackupSnapshot` value types

**Files:**
- Create: `Sources/AnyDoor/Models/BackupSnapshot.swift`
- Test: `Tests/AnyDoorTests/BackupCodecTests.swift` (created here, reused by Task 3)

- [ ] **Step 1: Write the failing test**

Create `Tests/AnyDoorTests/BackupCodecTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class BackupCodecTests: XCTestCase {

    func testSettingValueEncodesAndDecodesEachCase() throws {
        let values: [SettingValue] = [.bool(true), .int(42), .string("hi")]
        let data = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([SettingValue].self, from: data)
        XCTAssertEqual(decoded, values)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BackupCodecTests`
Expected: FAIL — `cannot find type 'SettingValue' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnyDoor/Models/BackupSnapshot.swift`:

```swift
import Foundation

/// Type-tagged scalar for whitelisted UserDefaults values so the JSON stays
/// strongly typed and decodes back into the correct Swift type.
enum SettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)

    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "bool":   self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int":    self = .int(try c.decode(Int.self, forKey: .value))
        case "string": self = .string(try c.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown SettingValue type \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v):   try c.encode("bool", forKey: .type);   try c.encode(v, forKey: .value)
        case .int(let v):    try c.encode("int", forKey: .type);    try c.encode(v, forKey: .value)
        case .string(let v): try c.encode("string", forKey: .type); try c.encode(v, forKey: .value)
        }
    }
}

/// One app shortcut. `appPath` is intentionally omitted — it is re-resolved
/// locally from `appBundleID` on import so paths stay machine-correct.
struct AppShortcutDTO: Codable, Equatable, Sendable {
    var appBundleID: String
    var appName: String
    var keyCode: Int
    var modifierFlags: Int
    var isEnabled: Bool
    var isVisible: Bool
    var displayOrder: Double
}

/// One builtin preference, keyed by `itemKey` (== `BuiltinItem.rawValue`).
struct BuiltinPreferenceDTO: Codable, Equatable, Sendable {
    var itemKey: String
    var isVisible: Bool
    var displayOrder: Double
    var keyCode: Int?
    var modifierFlags: Int?
}

/// The portable backup payload. `schemaVersion` gates future format migrations.
struct BackupSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var exportedAt: Date
    var appVersion: String
    var deviceName: String?
    var appShortcuts: [AppShortcutDTO]
    var builtinPreferences: [BuiltinPreferenceDTO]
    var settings: [String: SettingValue]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BackupCodecTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/BackupSnapshot.swift Tests/AnyDoorTests/BackupCodecTests.swift
git commit -m "feat(sync): add BackupSnapshot value types"
```

---

## Task 2: `SyncSettingsRegistry` (UserDefaults whitelist)

**Files:**
- Create: `Sources/AnyDoor/Services/SyncSettingsRegistry.swift`
- Test: `Tests/AnyDoorTests/SyncSettingsRegistryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnyDoorTests/SyncSettingsRegistryTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class SyncSettingsRegistryTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "SyncSettingsRegistryTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testExcludesMachineSpecificKeys() {
        let keys = Set(SyncSettingsRegistry.entries.map(\.key))
        XCTAssertFalse(keys.contains("hyperKey.ownedSignatures"))
        XCTAssertFalse(keys.contains("PortInventory.viewMode"))
        XCTAssertFalse(keys.contains("SUSkippedVersion"))
    }

    func testIncludesExpectedPortableKeys() {
        let keys = Set(SyncSettingsRegistry.entries.map(\.key))
        XCTAssertTrue(keys.contains("menuBar.iconVisible"))
        XCTAssertTrue(keys.contains("hyperKey.trigger"))
        XCTAssertTrue(keys.contains("dev.bybee.AnyDoor.language"))
    }

    func testReadCollectsOnlyPresentKeysWithCorrectTypes() {
        let d = makeDefaults()
        d.set(false, forKey: "menuBar.iconVisible")
        d.set(48, forKey: "commandPalette.hotkey.keyCode")
        d.set("zh", forKey: "dev.bybee.AnyDoor.language")
        // hyperKey.trigger deliberately not set → absent from result

        let result = SyncSettingsRegistry.read(from: d)

        XCTAssertEqual(result["menuBar.iconVisible"], .bool(false))
        XCTAssertEqual(result["commandPalette.hotkey.keyCode"], .int(48))
        XCTAssertEqual(result["dev.bybee.AnyDoor.language"], .string("zh"))
        XCTAssertNil(result["hyperKey.trigger"])
    }

    func testWriteAppliesValuesWithCorrectTypes() {
        let d = makeDefaults()
        SyncSettingsRegistry.write(
            ["menuBar.iconVisible": .bool(false),
             "commandPalette.hotkey.keyCode": .int(48),
             "dev.bybee.AnyDoor.language": .string("en")],
            to: d
        )
        XCTAssertEqual(d.bool(forKey: "menuBar.iconVisible"), false)
        XCTAssertEqual(d.integer(forKey: "commandPalette.hotkey.keyCode"), 48)
        XCTAssertEqual(d.string(forKey: "dev.bybee.AnyDoor.language"), "en")
    }

    func testWriteIgnoresKeysOutsideWhitelist() {
        let d = makeDefaults()
        SyncSettingsRegistry.write(["SUSkippedVersion": .string("9.9.9")], to: d)
        XCTAssertNil(d.string(forKey: "SUSkippedVersion"))
    }

    func testWriteIgnoresTypeMismatch() {
        let d = makeDefaults()
        // menuBar.iconVisible expects bool; an int payload must be ignored.
        SyncSettingsRegistry.write(["menuBar.iconVisible": .int(1)], to: d)
        XCTAssertNil(d.object(forKey: "menuBar.iconVisible"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SyncSettingsRegistryTests`
Expected: FAIL — `cannot find 'SyncSettingsRegistry' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnyDoor/Services/SyncSettingsRegistry.swift`:

```swift
import Foundation

/// Single source of truth for which UserDefaults keys are portable across
/// machines, plus their value type. Machine-specific keys
/// (`hyperKey.ownedSignatures`, `PortInventory.viewMode`, `SUSkippedVersion`)
/// are deliberately absent.
enum SyncSettingsRegistry {

    enum ValueType { case bool, int, string }

    struct Entry {
        let key: String
        let type: ValueType
    }

    static let entries: [Entry] = [
        Entry(key: "menuBar.iconVisible", type: .bool),
        Entry(key: "menuBar.iconName", type: .string),
        Entry(key: "commandPalette.hotkey.keyCode", type: .int),
        Entry(key: "commandPalette.hotkey.modifierFlags", type: .int),
        Entry(key: "dev.bybee.AnyDoor.language", type: .string),
        Entry(key: "hyperKey.trigger", type: .string),
        Entry(key: "hyperKey.quickPress", type: .string),
        Entry(key: "hyperKey.includeShift", type: .bool),
    ]

    private static let entriesByKey: [String: Entry] =
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })

    /// Collect whitelisted keys that are actually present in `defaults`.
    static func read(from defaults: UserDefaults) -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        for entry in entries {
            guard defaults.object(forKey: entry.key) != nil else { continue }
            switch entry.type {
            case .bool:   out[entry.key] = .bool(defaults.bool(forKey: entry.key))
            case .int:    out[entry.key] = .int(defaults.integer(forKey: entry.key))
            case .string:
                if let s = defaults.string(forKey: entry.key) {
                    out[entry.key] = .string(s)
                }
            }
        }
        return out
    }

    /// Write whitelisted values into `defaults`. Keys outside the whitelist and
    /// values whose type doesn't match the entry are ignored.
    static func write(_ values: [String: SettingValue], to defaults: UserDefaults) {
        for (key, value) in values {
            guard let entry = entriesByKey[key] else { continue }
            switch (entry.type, value) {
            case (.bool, .bool(let v)):     defaults.set(v, forKey: key)
            case (.int, .int(let v)):       defaults.set(v, forKey: key)
            case (.string, .string(let v)): defaults.set(v, forKey: key)
            default: continue
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SyncSettingsRegistryTests`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/SyncSettingsRegistry.swift Tests/AnyDoorTests/SyncSettingsRegistryTests.swift
git commit -m "feat(sync): add SyncSettingsRegistry UserDefaults whitelist"
```

---

## Task 3: `BackupCodec` (JSON encode/decode)

**Files:**
- Create: `Sources/AnyDoor/Services/BackupCodec.swift`
- Test: `Tests/AnyDoorTests/BackupCodecTests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append these methods to the existing `BackupCodecTests` class in `Tests/AnyDoorTests/BackupCodecTests.swift`:

```swift
    private func sampleSnapshot() -> BackupSnapshot {
        BackupSnapshot(
            schemaVersion: BackupSnapshot.currentSchemaVersion,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.2.3",
            deviceName: "Test-Mac",
            appShortcuts: [
                AppShortcutDTO(appBundleID: "com.apple.Safari", appName: "Safari",
                               keyCode: 4, modifierFlags: 256,
                               isEnabled: true, isVisible: true, displayOrder: 100)
            ],
            builtinPreferences: [
                BuiltinPreferenceDTO(itemKey: "darkMode", isVisible: true,
                                     displayOrder: 200, keyCode: 2, modifierFlags: 256)
            ],
            settings: ["menuBar.iconVisible": .bool(true)]
        )
    }

    func testSnapshotRoundTrips() throws {
        let original = sampleSnapshot()
        let data = try BackupCodec.encode(original)
        let decoded = try BackupCodec.decode(data)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeRejectsUnsupportedSchemaVersion() throws {
        var future = sampleSnapshot()
        future.schemaVersion = 999
        let data = try BackupCodec.encode(future)
        XCTAssertThrowsError(try BackupCodec.decode(data)) { error in
            XCTAssertEqual(error as? BackupCodecError, .unsupportedSchemaVersion(999))
        }
    }

    func testDecodeRejectsGarbage() {
        let garbage = Data("not json".utf8)
        XCTAssertThrowsError(try BackupCodec.decode(garbage))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BackupCodecTests`
Expected: FAIL — `cannot find 'BackupCodec' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnyDoor/Services/BackupCodec.swift`:

```swift
import Foundation

enum BackupCodecError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

/// Serializes `BackupSnapshot` to/from pretty-printed JSON with ISO8601 dates.
/// The single place future schema migrations will live.
enum BackupCodec {

    static func encode(_ snapshot: BackupSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> BackupSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(BackupSnapshot.self, from: data)
        guard snapshot.schemaVersion <= BackupSnapshot.currentSchemaVersion else {
            throw BackupCodecError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        return snapshot
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BackupCodecTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/BackupCodec.swift Tests/AnyDoorTests/BackupCodecTests.swift
git commit -m "feat(sync): add BackupCodec JSON serialization"
```

---

## Task 4: `SyncBackend` protocol + `LocalFileBackend`

**Files:**
- Create: `Sources/AnyDoor/Services/SyncBackend.swift`
- Test: `Tests/AnyDoorTests/BackupCodecTests.swift` (append — local file round-trip)

- [ ] **Step 1: Write the failing test**

Append to `BackupCodecTests` in `Tests/AnyDoorTests/BackupCodecTests.swift`:

```swift
    func testLocalFileBackendUploadThenDownload() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-backup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let backend = LocalFileBackend(url: url)
        let payload = Data("hello".utf8)
        try await backend.upload(payload)
        let read = try await backend.download()
        XCTAssertEqual(read, payload)
    }

    func testLocalFileBackendDownloadReturnsNilWhenMissing() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-missing-\(UUID().uuidString).json")
        let backend = LocalFileBackend(url: url)
        let read = try await backend.download()
        XCTAssertNil(read)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BackupCodecTests`
Expected: FAIL — `cannot find 'LocalFileBackend' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnyDoor/Services/SyncBackend.swift`:

```swift
import Foundation

/// Where backup bytes live. Implementations move an opaque blob; serialization
/// is `BackupCodec`'s job. Future backends (iCloud, Gist, S3) conform here.
protocol SyncBackend: Sendable {
    var displayName: String { get }
    func upload(_ data: Data) async throws
    /// Returns nil when no backup exists yet at this location.
    func download() async throws -> Data?
}

/// Reads/writes a single JSON file at a fixed URL. The UI supplies the URL via
/// NSSavePanel (export) / NSOpenPanel (import).
struct LocalFileBackend: SyncBackend {
    let url: URL

    var displayName: String { "本地文件" }

    func upload(_ data: Data) async throws {
        try data.write(to: url, options: .atomic)
    }

    func download() async throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BackupCodecTests`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/SyncBackend.swift Tests/AnyDoorTests/BackupCodecTests.swift
git commit -m "feat(sync): add SyncBackend protocol and LocalFileBackend"
```

---

## Task 5: `BackupService.exportSnapshot()`

**Files:**
- Create: `Sources/AnyDoor/Services/BackupService.swift`
- Test: `Tests/AnyDoorTests/BackupServiceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnyDoorTests/BackupServiceTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AnyDoor

final class BackupServiceTests: XCTestCase {

    @MainActor
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self, ClipboardHistoryItem.self,
            configurations: config
        )
        return container.mainContext
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "BackupServiceTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @MainActor
    func testExportCollectsShortcutsPreferencesAndSettings() throws {
        let context = try makeContext()
        context.insert(KeyBinding(keyCode: 4, modifierFlags: 256,
                                  appBundleID: "com.apple.Safari", appName: "Safari",
                                  appPath: "/Applications/Safari.app",
                                  isEnabled: true, isVisible: true, displayOrder: 100))
        context.insert(BuiltinPreference(itemKey: "darkMode", isVisible: true,
                                         displayOrder: 200, keyCode: 2, modifierFlags: 256))
        try context.save()

        let defaults = makeDefaults()
        defaults.set("zh", forKey: "dev.bybee.AnyDoor.language")

        let service = BackupService(context: context, defaults: defaults,
                                    appPathResolver: { _ in nil })
        let snapshot = service.exportSnapshot()

        XCTAssertEqual(snapshot.schemaVersion, BackupSnapshot.currentSchemaVersion)
        XCTAssertEqual(snapshot.appShortcuts.count, 1)
        XCTAssertEqual(snapshot.appShortcuts.first?.appBundleID, "com.apple.Safari")
        XCTAssertEqual(snapshot.builtinPreferences.first?.itemKey, "darkMode")
        XCTAssertEqual(snapshot.settings["dev.bybee.AnyDoor.language"], .string("zh"))
    }

    @MainActor
    func testExportOmitsAppPath() throws {
        // AppShortcutDTO has no appPath property — this is a compile-time guarantee.
        // The test documents intent: the exported shortcut carries only the bundle ID.
        let context = try makeContext()
        context.insert(KeyBinding(keyCode: 4, modifierFlags: 256,
                                  appBundleID: "com.apple.Safari", appName: "Safari",
                                  appPath: "/Users/alice/Applications/Safari.app",
                                  isEnabled: true, isVisible: true, displayOrder: 100))
        try context.save()

        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil })
        let snapshot = service.exportSnapshot()
        XCTAssertEqual(snapshot.appShortcuts.first?.appBundleID, "com.apple.Safari")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BackupServiceTests`
Expected: FAIL — `cannot find 'BackupService' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnyDoor/Services/BackupService.swift`:

```swift
import Foundation
import AppKit
import SwiftData

/// Outcome of an import, surfaced to the UI.
struct ImportSummary: Equatable {
    var shortcutsUpdated: Int
    var shortcutsInserted: Int
    var preferencesUpdated: Int
    var settingsApplied: Int
}

/// Gathers local config into a `BackupSnapshot` (export) and merges a snapshot
/// back into local state (import). Operates on an injected `ModelContext` +
/// `UserDefaults` so it is fully testable with an in-memory container.
@MainActor
final class BackupService {
    private let context: ModelContext
    private let defaults: UserDefaults
    private let appPathResolver: (String) -> String?

    /// - Parameter appPathResolver: bundleID → absolute path. Defaults to
    ///   `NSWorkspace`. Injected as `{ _ in nil }` in tests.
    init(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        appPathResolver: @escaping (String) -> String? = { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        }
    ) {
        self.context = context
        self.defaults = defaults
        self.appPathResolver = appPathResolver
    }

    // MARK: - Export

    func exportSnapshot() -> BackupSnapshot {
        let bindings = (try? context.fetch(
            FetchDescriptor<KeyBinding>(sortBy: [SortDescriptor(\.displayOrder)])
        )) ?? []
        let shortcuts = bindings.map { b in
            AppShortcutDTO(
                appBundleID: b.appBundleID, appName: b.appName,
                keyCode: b.keyCode, modifierFlags: b.modifierFlags,
                isEnabled: b.isEnabled, isVisible: b.isVisible,
                displayOrder: b.displayOrder
            )
        }

        let prefs = (try? context.fetch(
            FetchDescriptor<BuiltinPreference>(sortBy: [SortDescriptor(\.displayOrder)])
        )) ?? []
        let preferences = prefs.map { p in
            BuiltinPreferenceDTO(
                itemKey: p.itemKey, isVisible: p.isVisible,
                displayOrder: p.displayOrder,
                keyCode: p.keyCode, modifierFlags: p.modifierFlags
            )
        }

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"

        return BackupSnapshot(
            schemaVersion: BackupSnapshot.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            deviceName: Host.current().localizedName,
            appShortcuts: shortcuts,
            builtinPreferences: preferences,
            settings: SyncSettingsRegistry.read(from: defaults)
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BackupServiceTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/BackupService.swift Tests/AnyDoorTests/BackupServiceTests.swift
git commit -m "feat(sync): add BackupService.exportSnapshot"
```

---

## Task 6: `BackupService.importSnapshot()` — merge

**Files:**
- Modify: `Sources/AnyDoor/Services/BackupService.swift`
- Test: `Tests/AnyDoorTests/BackupServiceTests.swift` (append)

- [ ] **Step 1: Write the failing test**

Append to `BackupServiceTests`:

```swift
    @MainActor
    private func snapshot(
        shortcuts: [AppShortcutDTO] = [],
        prefs: [BuiltinPreferenceDTO] = [],
        settings: [String: SettingValue] = [:]
    ) -> BackupSnapshot {
        BackupSnapshot(
            schemaVersion: BackupSnapshot.currentSchemaVersion,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.0", deviceName: nil,
            appShortcuts: shortcuts, builtinPreferences: prefs, settings: settings
        )
    }

    @MainActor
    func testImportInsertsNewShortcutAndResolvesPath() throws {
        let context = try makeContext()
        let service = BackupService(
            context: context, defaults: makeDefaults(),
            appPathResolver: { id in id == "com.apple.Safari" ? "/Applications/Safari.app" : nil }
        )

        let summary = service.importSnapshot(snapshot(shortcuts: [
            AppShortcutDTO(appBundleID: "com.apple.Safari", appName: "Safari",
                           keyCode: 4, modifierFlags: 256,
                           isEnabled: true, isVisible: true, displayOrder: 100)
        ]))

        XCTAssertEqual(summary.shortcutsInserted, 1)
        let rows = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.appPath, "/Applications/Safari.app")
    }

    @MainActor
    func testImportInsertsShortcutWithEmptyPathWhenAppMissing() throws {
        let context = try makeContext()
        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil })
        let summary = service.importSnapshot(snapshot(shortcuts: [
            AppShortcutDTO(appBundleID: "com.unknown.App", appName: "Unknown",
                           keyCode: 4, modifierFlags: 256,
                           isEnabled: true, isVisible: true, displayOrder: 100)
        ]))
        XCTAssertEqual(summary.shortcutsInserted, 1)
        let rows = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(rows.first?.appPath, "")
    }

    @MainActor
    func testImportUpdatesExistingShortcutByBundleIDAndReresolvesPath() throws {
        let context = try makeContext()
        // Existing row carries a foreign-username path that must be replaced.
        context.insert(KeyBinding(keyCode: 0, modifierFlags: 0,
                                  appBundleID: "com.apple.Safari", appName: "Old Safari",
                                  appPath: "/Users/bob/Applications/Safari.app",
                                  isEnabled: false, isVisible: true, displayOrder: 999))
        try context.save()

        let service = BackupService(
            context: context, defaults: makeDefaults(),
            appPathResolver: { _ in "/Applications/Safari.app" }
        )
        let summary = service.importSnapshot(snapshot(shortcuts: [
            AppShortcutDTO(appBundleID: "com.apple.Safari", appName: "Safari",
                           keyCode: 4, modifierFlags: 256,
                           isEnabled: true, isVisible: true, displayOrder: 100)
        ]))

        XCTAssertEqual(summary.shortcutsUpdated, 1)
        XCTAssertEqual(summary.shortcutsInserted, 0)
        let rows = try context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.keyCode, 4)
        XCTAssertEqual(rows.first?.appName, "Safari")
        XCTAssertEqual(rows.first?.isEnabled, true)
        XCTAssertEqual(rows.first?.appPath, "/Applications/Safari.app")
    }

    @MainActor
    func testImportKeepsLocalOnlyShortcuts() throws {
        let context = try makeContext()
        context.insert(KeyBinding(keyCode: 5, modifierFlags: 256,
                                  appBundleID: "com.local.Only", appName: "Local",
                                  appPath: "/Applications/Local.app",
                                  isEnabled: true, isVisible: true, displayOrder: 100))
        try context.save()

        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil })
        _ = service.importSnapshot(snapshot(shortcuts: [
            AppShortcutDTO(appBundleID: "com.other.App", appName: "Other",
                           keyCode: 4, modifierFlags: 256,
                           isEnabled: true, isVisible: true, displayOrder: 200)
        ]))

        let ids = try context.fetch(FetchDescriptor<KeyBinding>()).map(\.appBundleID).sorted()
        XCTAssertEqual(ids, ["com.local.Only", "com.other.App"])
    }

    @MainActor
    func testImportUpdatesExistingPreferenceByItemKey() throws {
        let context = try makeContext()
        context.insert(BuiltinPreference(itemKey: "darkMode", isVisible: false,
                                         displayOrder: 999, keyCode: nil, modifierFlags: nil))
        try context.save()

        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil })
        let summary = service.importSnapshot(snapshot(prefs: [
            BuiltinPreferenceDTO(itemKey: "darkMode", isVisible: true,
                                 displayOrder: 100, keyCode: 2, modifierFlags: 256)
        ]))

        XCTAssertEqual(summary.preferencesUpdated, 1)
        let pref = try context.fetch(FetchDescriptor<BuiltinPreference>()).first
        XCTAssertEqual(pref?.isVisible, true)
        XCTAssertEqual(pref?.keyCode, 2)
    }

    @MainActor
    func testImportSkipsPreferenceWithUnknownItemKey() throws {
        let context = try makeContext()
        let service = BackupService(context: context, defaults: makeDefaults(),
                                    appPathResolver: { _ in nil })
        // No local BuiltinPreference exists for this key; import must not insert
        // a row for a key the local catalog doesn't have.
        let summary = service.importSnapshot(snapshot(prefs: [
            BuiltinPreferenceDTO(itemKey: "darkMode", isVisible: true,
                                 displayOrder: 100, keyCode: nil, modifierFlags: nil)
        ]))
        XCTAssertEqual(summary.preferencesUpdated, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BuiltinPreference>()).count, 0)
    }

    @MainActor
    func testImportAppliesSettings() throws {
        let context = try makeContext()
        let defaults = makeDefaults()
        let service = BackupService(context: context, defaults: defaults,
                                    appPathResolver: { _ in nil })
        let summary = service.importSnapshot(snapshot(
            settings: ["menuBar.iconVisible": .bool(false),
                       "dev.bybee.AnyDoor.language": .string("en")]
        ))
        XCTAssertEqual(summary.settingsApplied, 2)
        XCTAssertEqual(defaults.bool(forKey: "menuBar.iconVisible"), false)
        XCTAssertEqual(defaults.string(forKey: "dev.bybee.AnyDoor.language"), "en")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BackupServiceTests`
Expected: FAIL — `value of type 'BackupService' has no member 'importSnapshot'`.

- [ ] **Step 3: Write minimal implementation**

Add to `BackupService` (inside the class, after `exportSnapshot`):

```swift
    // MARK: - Import (merge; import wins per key, local-only rows preserved)

    @discardableResult
    func importSnapshot(_ snapshot: BackupSnapshot) -> ImportSummary {
        var summary = ImportSummary(shortcutsUpdated: 0, shortcutsInserted: 0,
                                    preferencesUpdated: 0, settingsApplied: 0)

        // App shortcuts — match by appBundleID.
        let existingBindings = (try? context.fetch(FetchDescriptor<KeyBinding>())) ?? []
        var bindingsByID = Dictionary(
            existingBindings.map { ($0.appBundleID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for dto in snapshot.appShortcuts {
            let resolvedPath = appPathResolver(dto.appBundleID) ?? ""
            if let existing = bindingsByID[dto.appBundleID] {
                existing.keyCode = dto.keyCode
                existing.modifierFlags = dto.modifierFlags
                existing.isEnabled = dto.isEnabled
                existing.isVisible = dto.isVisible
                existing.displayOrder = dto.displayOrder
                existing.appName = dto.appName
                existing.appPath = resolvedPath
                summary.shortcutsUpdated += 1
            } else {
                let new = KeyBinding(
                    keyCode: dto.keyCode, modifierFlags: dto.modifierFlags,
                    appBundleID: dto.appBundleID, appName: dto.appName,
                    appPath: resolvedPath,
                    isEnabled: dto.isEnabled, isVisible: dto.isVisible,
                    displayOrder: dto.displayOrder
                )
                context.insert(new)
                bindingsByID[dto.appBundleID] = new
                summary.shortcutsInserted += 1
            }
        }

        // Builtin preferences — match by itemKey; never insert unknown keys
        // (the local catalog is the source of truth for which items exist).
        let existingPrefs = (try? context.fetch(FetchDescriptor<BuiltinPreference>())) ?? []
        let prefsByKey = Dictionary(
            existingPrefs.map { ($0.itemKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for dto in snapshot.builtinPreferences {
            guard let existing = prefsByKey[dto.itemKey] else { continue }
            existing.isVisible = dto.isVisible
            existing.displayOrder = dto.displayOrder
            existing.keyCode = dto.keyCode
            existing.modifierFlags = dto.modifierFlags
            summary.preferencesUpdated += 1
        }

        try? context.save()

        // Settings — whitelisted UserDefaults.
        SyncSettingsRegistry.write(snapshot.settings, to: defaults)
        summary.settingsApplied = snapshot.settings.keys.filter { key in
            SyncSettingsRegistry.entries.contains { $0.key == key }
        }.count

        return summary
    }

    /// Re-read settings into the services whose setters carry side effects that
    /// raw UserDefaults writes bypass. Call after `importSnapshot` on the live
    /// app (not needed in tests). Also rebuilds the panel + hotkey snapshots.
    func reconcileAfterImport() async {
        CommandPaletteService.shared.reloadFromDefaults()
        LocalizationManager.shared.reloadFromDefaults()
        await HyperKeyService.shared.reloadFromDefaults()
        PanelStore.shared.rebuild()
        PanelStore.shared.rebuildHotkeySnapshots()
    }
```

> Note: `settingsApplied` counts only whitelisted keys so an out-of-whitelist key in the payload isn't reported as applied. The three `reloadFromDefaults` methods are added in Task 7.

- [ ] **Step 4: Run test to verify it passes (the merge tests; reconcile is exercised in Task 7)**

The `reconcileAfterImport` body references methods added in Task 7 and will not compile yet. To keep this task green in isolation, temporarily comment out the three `reloadFromDefaults` lines (leave the two `PanelStore` calls), run the tests, then proceed to Task 7 which restores them.

Run: `swift test --filter BackupServiceTests`
Expected: PASS (all import tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/BackupService.swift Tests/AnyDoorTests/BackupServiceTests.swift
git commit -m "feat(sync): add BackupService.importSnapshot merge logic"
```

---

## Task 7: Service `reloadFromDefaults` hooks

**Files:**
- Modify: `Sources/AnyDoor/Services/CommandPaletteService.swift`
- Modify: `Sources/AnyDoor/Services/LocalizationManager.swift`
- Modify: `Sources/AnyDoor/Services/HyperKeyService.swift`
- Test: `Tests/AnyDoorTests/BackupServiceTests.swift` (append a CommandPalette reload test)

- [ ] **Step 1: Write the failing test**

Append to `BackupServiceTests`:

```swift
    @MainActor
    func testCommandPaletteReloadFromDefaultsPicksUpWrittenHotkey() {
        UserDefaults.standard.removeObject(forKey: "commandPalette.hotkey.keyCode")
        UserDefaults.standard.removeObject(forKey: "commandPalette.hotkey.modifierFlags")
        defer {
            UserDefaults.standard.removeObject(forKey: "commandPalette.hotkey.keyCode")
            UserDefaults.standard.removeObject(forKey: "commandPalette.hotkey.modifierFlags")
        }
        UserDefaults.standard.set(49, forKey: "commandPalette.hotkey.keyCode")
        UserDefaults.standard.set(256, forKey: "commandPalette.hotkey.modifierFlags")

        CommandPaletteService.shared.reloadFromDefaults()

        XCTAssertEqual(CommandPaletteService.shared.hotkey?.keyCode, 49)
        XCTAssertEqual(CommandPaletteService.shared.hotkey?.modifierFlags, 256)
    }
```

> This test uses `.standard` because `CommandPaletteService` is a singleton bound to `.standard`. It cleans up after itself.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BackupServiceTests/testCommandPaletteReloadFromDefaultsPicksUpWrittenHotkey`
Expected: FAIL — `value of type 'CommandPaletteService' has no member 'reloadFromDefaults'`.

- [ ] **Step 3: Write minimal implementation**

In `Sources/AnyDoor/Services/CommandPaletteService.swift`, add this method to the class (after `setHotkey`):

```swift
    /// Re-read the hotkey from UserDefaults after an external write (config import)
    /// and rebuild the hotkey snapshots so the CGEvent tap picks it up.
    func reloadFromDefaults() {
        hotkey = Self.readFromDefaults()
        PanelStore.shared.rebuildHotkeySnapshots()
    }
```

In `Sources/AnyDoor/Services/LocalizationManager.swift`, add this method to the class (after the `preference` computed property):

```swift
    /// Re-read the language preference from `defaults` after an external write
    /// (config import). Updates the observable `preference` without re-persisting.
    func reloadFromDefaults() {
        let raw = defaults.string(forKey: Self.defaultsKey)
        _preference = raw.flatMap(LanguagePreference.init(rawValue:)) ?? .system
    }
```

In `Sources/AnyDoor/Services/HyperKeyService.swift`, add this method to the class (after `setIncludeShift`):

```swift
    /// Re-read trigger/quickPress/includeShift from UserDefaults after an
    /// external write (config import) and re-apply the HID mapping.
    func reloadFromDefaults() async {
        let raw = defaults.string(forKey: triggerKey) ?? HyperKeyTrigger.none.rawValue
        trigger = HyperKeyTrigger(rawValue: raw) ?? .none
        let qpRaw = defaults.string(forKey: quickPressKey) ?? HyperKeyQuickPress.doesNothing.rawValue
        quickPress = HyperKeyQuickPress(rawValue: qpRaw) ?? .doesNothing
        includeShift = defaults.object(forKey: includeShiftKey) as? Bool ?? true
        await applyCurrent()
    }
```

Now restore the three `reloadFromDefaults` calls in `BackupService.reconcileAfterImport()` that were commented out in Task 6 (if they were). The final body must be:

```swift
    func reconcileAfterImport() async {
        CommandPaletteService.shared.reloadFromDefaults()
        LocalizationManager.shared.reloadFromDefaults()
        await HyperKeyService.shared.reloadFromDefaults()
        PanelStore.shared.rebuild()
        PanelStore.shared.rebuildHotkeySnapshots()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BackupServiceTests`
Expected: PASS (all BackupServiceTests).

Then run the full suite to confirm no regression in localization/command-palette tests:

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/CommandPaletteService.swift Sources/AnyDoor/Services/LocalizationManager.swift Sources/AnyDoor/Services/HyperKeyService.swift Sources/AnyDoor/Services/BackupService.swift Tests/AnyDoorTests/BackupServiceTests.swift
git commit -m "feat(sync): add reloadFromDefaults hooks for post-import reconcile"
```

---

## Task 8: Localization keys for the Sync tab

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift`
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`

The `LocalizationCoverageTests` test fails if any `L10n.Key` case lacks a catalog entry, so the key enum and the catalog must be updated together.

- [ ] **Step 1: Add the L10n.Key cases**

In `Sources/AnyDoor/Utilities/L10n.swift`, add these cases to the `L10n.Key` enum. Keep alphabetical-by-raw-value ordering — insert them in the `settings*` block (raw values start with `settings.sync.` which sorts after `settings.panel.*` and before `settings.tab.*`):

```swift
        case settingsSyncDescription = "settings.sync.description"
        case settingsSyncExportButton = "settings.sync.exportButton"
        case settingsSyncExportFailed = "settings.sync.exportFailed"
        case settingsSyncExportSuccess = "settings.sync.exportSuccess"
        case settingsSyncImportButton = "settings.sync.importButton"
        case settingsSyncImportFailed = "settings.sync.importFailed"
        case settingsSyncImportSuccess = "settings.sync.importSuccess"
        case settingsSyncSection = "settings.sync.section"
        case settingsTabSync = "settings.tab.sync"
```

Place the `settings.sync.*` cases immediately before the existing `settingsTabGeneral` case, and `settingsTabSync` immediately after `settingsTabPanel` (the file's ordering is alphabetical by raw value: `settings.sync.*` < `settings.tab.general` < `settings.tab.panel` < `settings.tab.sync`). Net: the four `settings.tab.*`/`settings.sync.*` entries end up as `…sync.section`, `settingsTabGeneral`, `settingsTabPanel`, `settingsTabSync`.

- [ ] **Step 2: Add the catalog entries**

In `Sources/AnyDoor/Resources/Localizable.xcstrings`, add these entries to the top-level `"strings"` object (JSON object — key order doesn't matter for the build, only valid JSON does):

```json
    "settings.sync.description" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Back up your app shortcuts, builtin preferences, and general settings to a file, or restore them from one. Restore merges into your current configuration." } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "将应用快捷键、内置项偏好和通用设置备份到文件,或从文件恢复。恢复会合并到当前配置中。" } }
      }
    },
    "settings.sync.exportButton" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Export to File…" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "导出到文件…" } }
      }
    },
    "settings.sync.exportFailed" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Export failed: %@" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "导出失败:%@" } }
      }
    },
    "settings.sync.exportSuccess" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Exported successfully." } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "导出成功。" } }
      }
    },
    "settings.sync.importButton" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Import from File…" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "从文件导入…" } }
      }
    },
    "settings.sync.importFailed" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Import failed: %@" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "导入失败:%@" } }
      }
    },
    "settings.sync.importSuccess" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Imported %1$d shortcuts and %2$d preferences." } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "已导入 %1$d 个快捷键和 %2$d 个偏好。" } }
      }
    },
    "settings.sync.section" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Backup & Restore" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "备份与恢复" } }
      }
    },
    "settings.tab.sync" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Sync" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "同步" } }
      }
    },
```

- [ ] **Step 3: Verify the catalog parses and coverage passes**

Run: `python3 -c "import json; json.load(open('Sources/AnyDoor/Resources/Localizable.xcstrings'))" && echo OK`
Expected: `OK`.

Run: `swift test --filter LocalizationCoverageTests`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(sync): add localization keys for the sync settings tab"
```

---

## Task 9: `SyncSettingsView` + wire the tab

**Files:**
- Create: `Sources/AnyDoor/Views/SyncSettingsView.swift`
- Modify: `Sources/AnyDoor/Views/SettingsView.swift`

This is UI glue around the already-tested service; verification is a build + manual smoke check rather than a unit test (consistent with the other settings views, which have no view-body unit tests for button actions).

- [ ] **Step 1: Create the view**

Create `Sources/AnyDoor/Views/SyncSettingsView.swift`:

```swift
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "sync")

@MainActor
struct SyncSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var statusMessage: String?
    @State private var isError = false

    var body: some View {
        Form {
            Section {
                LocalizedText(.settingsSyncDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button { exportConfig() } label: {
                        LocalizedText(.settingsSyncExportButton)
                    }
                    Button { importConfig() } label: {
                        LocalizedText(.settingsSyncImportButton)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(isError ? .red : .secondary)
                }
            } header: {
                LocalizedText(.settingsSyncSection)
            }
        }
        .formStyle(.grouped)
    }

    private func makeService() -> BackupService {
        BackupService(context: modelContext, defaults: .standard)
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AnyDoor-Backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = makeService().exportSnapshot()
            let data = try BackupCodec.encode(snapshot)
            try LocalFileBackend(url: url).uploadSync(data)
            statusMessage = L(.settingsSyncExportSuccess)
            isError = false
        } catch {
            logger.error("Export failed: \(error)")
            statusMessage = L(.settingsSyncExportFailed, error.localizedDescription)
            isError = true
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = try LocalFileBackend(url: url).downloadSync() else {
                statusMessage = L(.settingsSyncImportFailed, "no data")
                isError = true
                return
            }
            let snapshot = try BackupCodec.decode(data)
            let service = makeService()
            let summary = service.importSnapshot(snapshot)
            Task { await service.reconcileAfterImport() }
            statusMessage = L(.settingsSyncImportSuccess,
                              summary.shortcutsUpdated + summary.shortcutsInserted,
                              summary.preferencesUpdated)
            isError = false
        } catch {
            logger.error("Import failed: \(error)")
            statusMessage = L(.settingsSyncImportFailed, error.localizedDescription)
            isError = true
        }
    }
}
```

- [ ] **Step 2: Add synchronous file helpers to LocalFileBackend**

The view runs inside synchronous button actions after a modal panel; `LocalFileBackend`'s async API is awkward there. Add synchronous siblings used only by the local file flow. In `Sources/AnyDoor/Services/SyncBackend.swift`, add inside `LocalFileBackend`:

```swift
    /// Synchronous variant for the panel-driven local flow (a save panel already
    /// blocked the main thread; the write is small). Cloud backends use the async API.
    func uploadSync(_ data: Data) throws {
        try data.write(to: url, options: .atomic)
    }

    func downloadSync() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
```

- [ ] **Step 3: Wire the tab**

In `Sources/AnyDoor/Views/SettingsView.swift`, add the third tab after `GeneralSettingsView`'s `.tabItem`:

```swift
            SyncSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabSync) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                }
```

The full `SettingsView` body becomes:

```swift
        TabView {
            PanelSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabPanel) } icon: { Image(systemName: "rectangle.stack") }
                }

            GeneralSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabGeneral) } icon: { Image(systemName: "gear") }
                }

            SyncSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabSync) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                }
        }
        .frame(width: 560, height: 480)
```

- [ ] **Step 4: Build and verify**

Run: `swift build`
Expected: build succeeds with no errors.

Run: `swift test`
Expected: PASS (full suite, including LocalizationCoverageTests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/SyncSettingsView.swift Sources/AnyDoor/Views/SettingsView.swift Sources/AnyDoor/Services/SyncBackend.swift
git commit -m "feat(sync): add Sync settings tab with file export/import"
```

---

## Task 10: Manual smoke test + final verification

**Files:** none (verification only)

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: all tests PASS.

- [ ] **Step 2: Manual smoke test**

Run: `swift run AnyDoor`
Then:
1. Open Settings → the third "同步" tab appears.
2. Add an app shortcut + set a builtin hotkey in the other tabs first (so there is data).
3. Click "导出到文件…", save `AnyDoor-Backup.json`. Confirm the file exists and is readable JSON (`python3 -m json.tool AnyDoor-Backup.json`).
4. Change a setting (e.g. menu bar icon visibility), then "从文件导入…" the saved file. Confirm the imported value is restored and the success message shows the counts.
5. Confirm app shortcuts still fire (hotkey snapshots rebuilt) and language/menu-bar reflect imported values.

- [ ] **Step 3: Confirm the design's out-of-scope items were not implemented**

Verify no automatic sync, no cloud backend, no clipboard history in the snapshot (grep the snapshot file for clipboard — should be absent).

Run: `grep -i clipboard AnyDoor-Backup.json; echo "exit: $?"`
Expected: no matches (`exit: 1`).

- [ ] **Step 4: Clean up the smoke-test artifact**

```bash
rm -f AnyDoor-Backup.json
```

---

## Self-Review Notes (for the implementer)

- **Spec coverage:** App shortcuts (Tasks 5–6), builtin preferences (Tasks 5–6), whitelisted settings (Tasks 2, 5–6), merge-by-bundle-ID with path re-resolution (Task 6), pluggable backend (Task 4), local file first (Tasks 4, 9), Settings UI (Task 9), clipboard excluded (Task 10 verification). All covered.
- **Type consistency:** `reloadFromDefaults()` is sync on `CommandPaletteService`/`LocalizationManager` and `async` on `HyperKeyService` — `reconcileAfterImport` awaits only the HyperKey one. `ImportSummary` fields match between definition (Task 5) and use (Tasks 6, 9). `LocalFileBackend` exposes both async (`upload`/`download`) and sync (`uploadSync`/`downloadSync`) variants; the view uses the sync pair.
- **Catalog:** every new `L10n.Key` (Task 8) has a matching `settings.sync.*` / `settings.tab.sync` entry; `%1$d`/`%2$d` positional args in `importSuccess` match the two-arg `L(.settingsSyncImportSuccess, …)` call.
```
