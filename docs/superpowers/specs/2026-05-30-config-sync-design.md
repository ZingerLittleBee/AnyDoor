# Config Sync — Design

Date: 2026-05-30
Status: Approved (design), pending implementation plan

## Goal

Let users back up and restore their AnyDoor configuration across machines.
Three data groups are in scope:

1. **App shortcuts** — `KeyBinding` (per-app global toggle hotkeys)
2. **Builtin preferences** — `BuiltinPreference` (visibility / order / hotkey of
   system toggle & action items)
3. **General settings** — a whitelisted subset of `UserDefaults`

Clipboard history (`ClipboardHistoryItem`) is **out of scope** (privacy + size).

Storage must be **pluggable** across multiple backends (iCloud, GitHub Gist,
S3, …). First delivered backend is **local file import/export**; cloud backends
slot in behind the same protocol with no changes to the serialization or merge
logic.

## Sync model

**Manual backup / restore.** No automatic/background sync, no conflict-merge
engine, no version vectors. The user explicitly exports (uploads) or imports
(downloads). This keeps the architecture simple and predictable for the MVP.

Restore semantics: **merge, import wins per key**. Items present in the backup
overwrite the matching local item; local-only items are kept (never deleted).

## Architecture

```
SyncSettingsView (UI)
      │  export / import actions, file panels
      ▼
BackupService (@MainActor)
   exportSnapshot() -> BackupSnapshot
   importSnapshot(_:)            // merge into SwiftData + UserDefaults
      │
      ├── reads/writes SwiftData (KeyBinding, BuiltinPreference) via PanelStore
      ├── reads/writes UserDefaults via SyncSettingsRegistry (whitelist)
      └── reconcileServicesAfterImport()
      ▼
BackupCodec     BackupSnapshot <-> Data (JSON)
      ▼
SyncBackend (protocol)  upload(Data) / download() -> Data?
      └── LocalFileBackend(url:)   [first impl]
          ICloudBackend / GistBackend / S3Backend  [later]
```

### 1. `BackupSnapshot` (Codable value type)

```
struct BackupSnapshot: Codable {
    var schemaVersion: Int          // = 1; reserved for future format migration
    var exportedAt: Date
    var appVersion: String
    var deviceName: String?         // display only
    var appShortcuts: [AppShortcutDTO]
    var builtinPreferences: [BuiltinPreferenceDTO]
    var settings: [String: SettingValue]   // whitelisted UserDefaults
}

struct AppShortcutDTO: Codable {
    var appBundleID: String         // identity key for merge
    var appName: String
    var keyCode: Int
    var modifierFlags: Int
    var isEnabled: Bool
    var isVisible: Bool
    var displayOrder: Double
    // appPath intentionally OMITTED — re-resolved locally on import
}

struct BuiltinPreferenceDTO: Codable {
    var itemKey: String             // identity key for merge
    var isVisible: Bool
    var displayOrder: Double
    var keyCode: Int?
    var modifierFlags: Int?
}

enum SettingValue: Codable {        // type-tagged for safe JSON
    case bool(Bool)
    case int(Int)
    case string(String)
}
```

**Why no `appPath`:** absolute paths embed the username and install location,
which differ across machines. Identity and merge are keyed on `appBundleID`;
the path is re-resolved on import via
`NSWorkspace.shared.urlForApplication(withBundleIdentifier:)`. If the app is not
installed locally, the binding is still imported (path left empty) and becomes
functional once the app is installed.

### 2. `SyncSettingsRegistry` (UserDefaults whitelist)

Single source of truth for which `UserDefaults` keys are portable and their
value type.

**Synced (portable):**

| Key                                 | Type   | Owner |
|-------------------------------------|--------|-------|
| `menuBar.iconVisible`               | Bool   | MenuBarIcon |
| `menuBar.iconName`                  | String | MenuBarIcon |
| `commandPalette.hotkey.keyCode`     | Int    | CommandPaletteService |
| `commandPalette.hotkey.modifierFlags` | Int  | CommandPaletteService |
| `dev.bybee.AnyDoor.language`        | String | LocalizationManager |
| `hyperKey.trigger`                  | String | HyperKeyService |
| `hyperKey.quickPress`               | String | HyperKeyService |
| `hyperKey.includeShift`             | Bool   | HyperKeyService |

**Excluded (machine-specific):**

- `hyperKey.ownedSignatures` — HID mapping recovery state, machine-local
- `PortInventory.viewMode` — transient local UI state
- `SUSkippedVersion` — Sparkle, machine-local

### 3. `BackupService` (@MainActor)

- `exportSnapshot() -> BackupSnapshot`
  - Fetch `KeyBinding` + `BuiltinPreference` from the shared `ModelContext`.
  - Read whitelisted `UserDefaults` keys via `SyncSettingsRegistry`.
  - Stamp `appVersion`, `exportedAt`, `deviceName`.

- `importSnapshot(_:) -> ImportSummary`  (merge)
  - **App shortcuts:** build `[appBundleID: KeyBinding]` from existing rows.
    For each DTO: if present, update `keyCode/modifierFlags/isEnabled/isVisible/
    displayOrder/appName` and re-resolve `appPath`; if absent, insert a new
    `KeyBinding` with resolved path. Never delete local-only rows.
  - **Builtin preferences:** match by `itemKey`, write through a PanelStore
    batch mutation method (so SwiftData save + view rebuild + hotkey-snapshot
    rebuild stay on the sanctioned write path per CLAUDE.md).
  - **Settings:** write each whitelisted key present in the snapshot to
    `UserDefaults` with the correct type.
  - Finalize: `context.save()` → `PanelStore.rebuild()` +
    `rebuildHotkeySnapshots()` → `reconcileServicesAfterImport()`.
  - Return an `ImportSummary` (counts) for UI feedback.

- `reconcileServicesAfterImport()`
  - Writing `UserDefaults` directly bypasses service setters that carry side
    effects (registering hotkeys, applying the HID mapping, refreshing the
    in-memory localized state, redrawing the menu bar). After the raw writes,
    nudge the affected services to re-read:
    - `HyperKeyService` re-reads trigger/quickPress/includeShift and re-applies
      the HID mapping via `HyperKeyController`.
    - `CommandPaletteService` re-registers its hotkey.
    - `LocalizationManager` reloads the active language into its observable
      state.
    - Menu bar refresh already rides `UserDefaults.didChangeNotification`.

### 4. `SyncBackend` protocol + `BackupCodec`

```
protocol SyncBackend {
    var displayName: String { get }
    func upload(_ data: Data) async throws
    func download() async throws -> Data?
}
```

- `BackupCodec`: `encode(BackupSnapshot) -> Data` / `decode(Data) -> BackupSnapshot`
  using `JSONEncoder`/`JSONDecoder` (pretty-printed, ISO8601 dates). Validates
  `schemaVersion` on decode and is the single place future format migrations
  live.
- `LocalFileBackend(url:)`: the first implementation. The UI obtains a URL via
  `NSSavePanel` (export) / `NSOpenPanel` (import) and injects it. `upload`
  writes the bytes to the URL; `download` reads them.
- Cloud backends (`ICloudBackend`, `GistBackend`, `S3Backend`) conform to the
  same protocol later with no changes to `BackupService` / `BackupCodec`.

### 5. UI — `SyncSettingsView` (new Settings tab)

Add a third tab to `SettingsView`'s `TabView`, alongside 面板 and 通用:

```swift
SyncSettingsView()
    .tabItem {
        Label { LocalizedText(.settingsTabSync) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
    }
```

Contents:

- **导出到文件** button → `NSSavePanel` → `BackupCodec.encode` →
  `LocalFileBackend.upload`.
- **从文件导入** button → `NSOpenPanel` → `LocalFileBackend.download` →
  `BackupCodec.decode` → `BackupService.importSnapshot` → show summary
  ("导入了 N 个快捷键 / M 个偏好").
- Reserved area for future cloud backends (iCloud / Gist appear as options
  later).

Requires a new localization key `settingsTabSync` (and any button/result
strings), following the existing `LocalizedText` pattern. UI-facing strings stay
in Chinese.

## Testing

- `BackupSnapshot` round-trips through `BackupCodec` (encode → decode equals
  original).
- Merge algorithm: existing-row update, new-row insert, local-only preservation,
  `appPath` re-resolution by bundle ID, missing-app graceful import.
- `SettingValue` typed JSON encode/decode for bool/int/string.
- These are pure value/logic units testable without the UI.

## Out of scope (this iteration)

- Automatic / background sync and conflict merging.
- iCloud / Gist / S3 backend implementations (protocol is designed for them).
- Clipboard history sync.
- Overwrite-all or interactive choose-on-import restore modes.
