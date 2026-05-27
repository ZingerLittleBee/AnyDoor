# System Apps in App Shortcuts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `/Applications`-locked `NSOpenPanel` with a searchable SwiftUI picker so Finder and other system apps can be bound to App Shortcuts.

**Architecture:** A new `InstalledAppsScanner` returns `[InstalledApp]` by enumerating `.app` bundles in `/Applications`, `/System/Applications`, their `Utilities` subdirs, `~/Applications`, plus an explicit Finder probe at `/System/Library/CoreServices/Finder.app`. A new `AppPickerSheet` shows the scanned list with search, calls back into the existing `PanelStore.shared.addAppShortcut(...)` on selection. `KeyBinding`/`AppSwitcher`/`HotkeyService` are unchanged — the data path is already path-agnostic.

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftUI, AppKit (`Bundle`, `FileManager`, `NSWorkspace`), SwiftData (existing). Tests via `swift test`.

**Spec:** `docs/superpowers/specs/2026-05-27-system-apps-in-shortcuts-design.md`

---

## File Structure

- `Sources/AnyDoor/Services/InstalledAppsScanner.swift` (new) — pure logic: scan roots, build `[InstalledApp]`. `@MainActor` only because `NSWorkspace` is main-actor isolated; FS work uses `FileManager` which is thread-safe.
- `Sources/AnyDoor/Views/AppPickerSheet.swift` (new) — SwiftUI sheet view. Receives `[InstalledApp]`, `excludedBundleIDs`, `onSelect`, `onCancel`.
- `Sources/AnyDoor/Views/PanelSettingsView.swift` (modify) — drop NSOpenPanel branch, add `@State showingAppPicker`, present `.sheet`.
- `Sources/AnyDoor/Utilities/L10n.swift` (modify) — add 3 `Key` cases.
- `Sources/AnyDoor/Resources/Localizable.xcstrings` (modify) — add 3 entries (en + zh-Hans).
- `Tests/AnyDoorTests/InstalledAppsScannerTests.swift` (new) — verify scanner discovers Finder and dedupes by bundleID.

Files that change together:
- L10n key + xcstrings entry must land together (LocalizationCoverageTests will fail otherwise).
- `InstalledAppsScanner.swift` must include the `InstalledApp` struct (used by both scanner and sheet).

---

### Task 1: Create `InstalledApp` value type and failing scanner test

**Files:**
- Create: `Sources/AnyDoor/Services/InstalledAppsScanner.swift`
- Create: `Tests/AnyDoorTests/InstalledAppsScannerTests.swift`

- [ ] **Step 1: Create the scanner file skeleton with the value type only**

Write the file at `Sources/AnyDoor/Services/InstalledAppsScanner.swift`:

```swift
import AppKit
import Foundation

struct InstalledApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let displayName: String
    let path: String
    var id: String { bundleID }

    var isSystemApp: Bool { path.hasPrefix("/System/") }
}

@MainActor
enum InstalledAppsScanner {
    static func scan() -> [InstalledApp] {
        return []
    }
}
```

- [ ] **Step 2: Write the failing scanner test**

Write `Tests/AnyDoorTests/InstalledAppsScannerTests.swift`:

```swift
import XCTest
@testable import AnyDoor

@MainActor
final class InstalledAppsScannerTests: XCTestCase {
    func testScanFindsFinder() {
        let apps = InstalledAppsScanner.scan()
        let finder = apps.first { $0.bundleID == "com.apple.finder" }
        XCTAssertNotNil(finder, "Scanner must surface Finder so users can bind it to a shortcut")
        XCTAssertEqual(finder?.path, "/System/Library/CoreServices/Finder.app")
        XCTAssertTrue(finder?.isSystemApp ?? false)
    }

    func testScanResultsAreUniqueByBundleID() {
        let apps = InstalledAppsScanner.scan()
        let ids = apps.map(\.bundleID)
        XCTAssertEqual(ids.count, Set(ids).count, "Bundle IDs must be unique")
    }

    func testScanResultsAreSortedCaseInsensitively() {
        let apps = InstalledAppsScanner.scan()
        let names = apps.map(\.displayName)
        let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertEqual(names, sorted)
    }
}
```

- [ ] **Step 3: Run the test and confirm it fails**

Run:

```bash
swift test --filter InstalledAppsScannerTests
```

Expected: `testScanFindsFinder` fails (apps is empty). Other two pass trivially on an empty list — that is fine.

- [ ] **Step 4: Commit the failing test + skeleton**

```bash
git add Sources/AnyDoor/Services/InstalledAppsScanner.swift Tests/AnyDoorTests/InstalledAppsScannerTests.swift
git commit -m "test: failing scanner tests for system app discovery"
```

---

### Task 2: Implement `InstalledAppsScanner.scan()`

**Files:**
- Modify: `Sources/AnyDoor/Services/InstalledAppsScanner.swift`

- [ ] **Step 1: Replace the empty `scan()` body with the real implementation**

Open `Sources/AnyDoor/Services/InstalledAppsScanner.swift` and replace the entire `enum InstalledAppsScanner` block with:

```swift
@MainActor
enum InstalledAppsScanner {
    /// Roots scanned for `.app` bundles (direct children only).
    private static let scanRoots: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// Apps that don't live in any of `scanRoots` but should always be offered.
    private static let extraAppPaths: [String] = [
        "/System/Library/CoreServices/Finder.app",
    ]

    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var byBundleID: [String: InstalledApp] = [:]

        for root in scanRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(entry)
                if let app = makeApp(at: path), byBundleID[app.bundleID] == nil {
                    byBundleID[app.bundleID] = app
                }
            }
        }

        for path in extraAppPaths {
            guard fm.fileExists(atPath: path) else { continue }
            if let app = makeApp(at: path), byBundleID[app.bundleID] == nil {
                byBundleID[app.bundleID] = app
            }
        }

        return byBundleID.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func makeApp(at path: String) -> InstalledApp? {
        let url = URL(fileURLWithPath: path)
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier,
              !bundleID.isEmpty else {
            return nil
        }
        let info = bundle.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(bundleID: bundleID, displayName: name, path: path)
    }
}
```

- [ ] **Step 2: Run the scanner tests**

```bash
swift test --filter InstalledAppsScannerTests
```

Expected: all three tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/InstalledAppsScanner.swift
git commit -m "feat(services): InstalledAppsScanner enumerates system and user apps"
```

---

### Task 3: Add localization keys

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift`
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the three new cases to `L10n.Key`**

Open `Sources/AnyDoor/Utilities/L10n.swift`. Find the line:

```swift
case settingsAppPickerTitle = "settings.appPicker.title"
```

Insert these three cases immediately AFTER it (preserving alphabetical order — they all start with `settingsAppPicker`):

```swift
        case settingsAppPickerEmpty = "settings.appPicker.empty"
        case settingsAppPickerSearchPlaceholder = "settings.appPicker.searchPlaceholder"
        case settingsAppPickerSystemTag = "settings.appPicker.systemTag"
```

- [ ] **Step 2: Add the matching entries to the xcstrings catalog**

Open `Sources/AnyDoor/Resources/Localizable.xcstrings`. Find the `"settings.appPicker.title"` block (around line 599). Immediately AFTER its closing `},` and BEFORE the `"settings.general.about"` block, insert:

```json
    "settings.appPicker.empty" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "No matching apps" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "没有匹配的应用" } }
      }
    },
    "settings.appPicker.searchPlaceholder" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Search apps" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "搜索应用" } }
      }
    },
    "settings.appPicker.systemTag" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "System" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "系统" } }
      }
    },
```

- [ ] **Step 3: Run the localization coverage test**

```bash
swift test --filter LocalizationCoverageTests
```

Expected: PASS. (This test fails if any `L10n.Key` case lacks a catalog entry, or vice versa.)

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(l10n): add app picker search/empty/system strings"
```

---

### Task 4: Create the `AppPickerSheet` view

**Files:**
- Create: `Sources/AnyDoor/Views/AppPickerSheet.swift`

- [ ] **Step 1: Write the view**

Create `Sources/AnyDoor/Views/AppPickerSheet.swift`:

```swift
import SwiftUI
import AppKit

struct AppPickerSheet: View {
    let apps: [InstalledApp]
    let excludedBundleIDs: Set<String>
    let onSelect: (InstalledApp) -> Void
    let onCancel: () -> Void

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    private var filteredApps: [InstalledApp] {
        let pool = apps.filter { !excludedBundleIDs.contains($0.bundleID) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return pool }
        return pool.filter { app in
            app.displayName.localizedCaseInsensitiveContains(trimmed)
                || app.bundleID.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if filteredApps.isEmpty {
                emptyState
            } else {
                appList
            }

            Divider()

            footer
        }
        .frame(width: 480, height: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            LocalizedText(.settingsAppPickerTitle)
                .font(.headline)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L(.settingsAppPickerSearchPlaceholder), text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .onAppear { searchFocused = true }
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredApps) { app in
                    AppPickerRow(app: app) { onSelect(app) }
                    Divider().padding(.leading, 38)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            LocalizedText(.settingsAppPickerEmpty)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onCancel) {
                LocalizedText(.settingsPanelCancel)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }
}

private struct AppPickerRow: View {
    let app: InstalledApp
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if app.isSystemApp {
                        LocalizedText(.settingsAppPickerSystemTag)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(app.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovering ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
    }
}
```

- [ ] **Step 2: Build to confirm the view compiles**

```bash
swift build
```

Expected: build succeeds. If `LocalizedText` / `L(...)` signatures differ from what we wrote, fix the call sites to match the project's helpers as used in `AppShortcutsPopoverView.swift`.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/AppPickerSheet.swift
git commit -m "feat(views): AppPickerSheet — searchable installed-apps picker"
```

---

### Task 5: Wire the sheet into `PanelSettingsView`

**Files:**
- Modify: `Sources/AnyDoor/Views/PanelSettingsView.swift`

- [ ] **Step 1: Add picker state to `PanelSettingsView`**

Open `Sources/AnyDoor/Views/PanelSettingsView.swift`. Find the existing `@State` declarations at the top of `struct PanelSettingsView`:

```swift
struct PanelSettingsView: View {
    @State private var panel = PanelStore.shared
    @State private var conflictAlert: ConflictAlert?
    @State private var pendingDelete: PendingDelete?
```

Add two new `@State` lines directly below `pendingDelete`:

```swift
    @State private var pickerApps: [InstalledApp] = []
    @State private var showingAppPicker = false
```

- [ ] **Step 2: Attach the sheet modifier to `body`**

Find the end of the `body` `VStack` — the existing `.alert(item: $pendingDelete)` block. Immediately AFTER the closing `}` of that alert (still inside `body`), append:

```swift
        .sheet(isPresented: $showingAppPicker) {
            let excluded = Set(panel.appShortcutChildren.compactMap { entry -> String? in
                if case let .appShortcut(id) = entry.source,
                   let binding = PanelStore.shared.binding(id: id) {
                    return binding.appBundleID
                }
                return nil
            })
            AppPickerSheet(
                apps: pickerApps,
                excludedBundleIDs: excluded,
                onSelect: { app in
                    showingAppPicker = false
                    PanelStore.shared.addAppShortcut(
                        appBundleID: app.bundleID,
                        appName: app.displayName,
                        appPath: app.path
                    )
                },
                onCancel: { showingAppPicker = false }
            )
        }
```

- [ ] **Step 3: Rewrite `addApp()` to scan and present the sheet**

Find the existing `private func addApp()` block (currently the NSOpenPanel body) and replace its entire body with:

```swift
    private func addApp() {
        pickerApps = InstalledAppsScanner.scan()
        showingAppPicker = true
    }
```

The full replacement function:

```swift
    private func addApp() {
        pickerApps = InstalledAppsScanner.scan()
        showingAppPicker = true
    }
```

Remove the `import UniformTypeIdentifiers` line at the top of the file ONLY IF no other code in this file references `UTType` (`grep` the file first to confirm).

- [ ] **Step 4: Confirm `PanelStore.binding(id:)` is accessible**

Run:

```bash
grep -n "func binding" Sources/AnyDoor/Services/PanelStore.swift
```

Expected: a `func binding(id: UUID) -> KeyBinding?` (or equivalent) at internal/public access. If it's `private`, change it to internal in this step by removing the `private` keyword on that specific function.

- [ ] **Step 5: Build**

```bash
swift build
```

Expected: build succeeds. If a UTType-related error appears, restore `import UniformTypeIdentifiers`.

- [ ] **Step 6: Run the full test suite**

```bash
swift test
```

Expected: all tests pass (no behavioral regressions in store/hotkey/localization tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Views/PanelSettingsView.swift Sources/AnyDoor/Services/PanelStore.swift
git commit -m "feat(settings): present app picker sheet from + button"
```

(Include `PanelStore.swift` in `git add` only if Step 4 required a visibility change.)

---

### Task 6: Manual verification

**Files:** none modified.

- [ ] **Step 1: Launch the app**

```bash
swift run AnyDoor
```

Wait for the menu bar icon to appear. Grant Accessibility permission to the `swift run` binary identity if not already granted.

- [ ] **Step 2: Open the settings sheet**

Click the menu bar icon → 设置 (or invoke via the Settings shortcut). Switch to the 面板 tab. Locate the "+" button under App Shortcuts.

- [ ] **Step 3: Verify Finder is discoverable**

Click "+". A sheet appears with a search field and an apps list. Type `Finder`. Expected: a single row "Finder" with the "系统" tag, path `/System/Library/CoreServices/Finder.app`. Click it. Sheet dismisses.

- [ ] **Step 4: Verify the row appears in App Shortcuts**

A new row "Finder" appears in the panel list with no hotkey assigned. Click the hotkey recorder and bind a unique combo (e.g. `⌃⌥⌘F`).

- [ ] **Step 5: Verify the hotkey toggles Finder**

Bring another app to the front. Press `⌃⌥⌘F`. Expected: Finder activates. Press again. Expected: Finder hides (its windows go away or it ceases to be `isActive`).

- [ ] **Step 6: Verify other system apps work**

Repeat the picker flow with `Calculator` (in `/System/Applications`) and `System Settings`. Each should be discoverable, addable, and toggle-bindable.

- [ ] **Step 7: Verify already-added apps are filtered**

Open the picker again. Confirm that Finder, Calculator, and System Settings no longer appear in the list (they are excluded because they're already bound).

- [ ] **Step 8: Verify persistence**

Quit the app (menu bar → 退出). Re-run `swift run AnyDoor`. Confirm the Finder/Calculator/System Settings shortcuts persist and their hotkeys still toggle correctly.

- [ ] **Step 9: Note results**

If any step regresses, return to the relevant task and add a follow-up step. Do NOT create a PR (per user instruction).

---

## Self-Review Notes

- Spec coverage: §Components 1 → Task 1+2. §Components 2 → Task 4. §Components 3 → Task 5. §Components 4 (localization) → Task 3. §Testing → Task 6. ✓
- Placeholders: none ("appropriate", "TBD", "etc." not used in actionable steps). ✓
- Type consistency: `InstalledApp(bundleID:displayName:path:)` and `InstalledAppsScanner.scan()` signatures match across tasks 1, 2, 4, 5. `settingsAppPickerEmpty`/`SearchPlaceholder`/`SystemTag` cases match xcstrings keys. ✓
- Risk: `LocalizedText(.settingsPanelCancel)` referenced in Task 4 — verify this case exists (it's used by the existing alert footer at `PanelSettingsView.swift:31`, so it does).
