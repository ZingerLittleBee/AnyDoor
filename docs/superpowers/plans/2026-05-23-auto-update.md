# Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship in-app auto-updates for AnyDoor using Sparkle 2 with assets distributed via GitHub Releases, plus a local `make release` pipeline that signs and notarizes every artifact.

**Architecture:** Add Sparkle 2 as an SPM dependency and host a single `SPUStandardUpdaterController` on `AppDelegate`. Wrap it in a `@MainActor @Observable UpdateService` (with an `UpdaterAdapter` protocol for testability) so SwiftUI never imports Sparkle directly. Surface updates via Sparkle's standard dialogs, an in-panel banner in `MenuBarView`, and a new section in `GeneralSettingsView`. Distribute updates as version-pinned zips inside GitHub Releases alongside a cumulative `appcast.xml`; first-time downloads use a DMG. Releases are produced by a local `scripts/release.sh` driven from `make release [VERSION=x.y.z]`.

**Tech Stack:**
- Swift 6.2 strict concurrency, macOS 26
- Sparkle 2 (`sparkle-project/Sparkle`) pinned to 2.9.2
- SwiftUI + AppKit (existing `MenuBarController`, `GeneralSettingsView`)
- XCTest (existing `AnyDoorTests` target)
- Bash, `ditto`, `codesign`, `notarytool`, `stapler`, `gh`, `create-dmg`

**Spec:** `docs/superpowers/specs/2026-05-23-auto-update-design.md`

---

## File Structure

### Files created

| File | Responsibility |
|---|---|
| `Sources/AnyDoor/Services/UpdaterAdapter.swift` | `@MainActor` protocol abstracting `SPUUpdater` for tests; one type only |
| `Sources/AnyDoor/Services/UpdateService.swift` | `@MainActor @Observable` façade; mirrors updater state, filters skipped versions, exposes UI bindings |
| `Sources/AnyDoor/Views/UpdateBannerView.swift` | Banner row rendered at the top of `MenuBarView` when an update is available |
| `Tests/AnyDoorTests/UpdateServiceTests.swift` | Unit tests using a fake `UpdaterAdapter` |
| `CHANGELOG.md` | Keep-a-Changelog source for release notes |
| `scripts/install-sparkle-tools.sh` | Downloads Sparkle release tarball, extracts `sign_update` and `generate_appcast` into `scripts/sparkle-bin/` |
| `scripts/bump-version.sh` | Resolves and writes `CFBundleShortVersionString`/`CFBundleVersion` in `Info.plist` |
| `scripts/release.sh` | End-to-end release driver (preflight → build → sign → notarize → package → appcast → publish) |

### Files modified

| File | Change |
|---|---|
| `Package.swift` | Add Sparkle SPM dependency |
| `Info.plist` | Add `SUFeedURL`, `SUPublicEDKey`, `SUEnableSystemProfiling` |
| `Sources/AnyDoor/AppDelegate.swift` | Bootstrap `SPUStandardUpdaterController` behind a `shouldStartUpdater()` guard |
| `Sources/AnyDoor/Services/MenuBarController.swift` | Inject `UpdateService` into `MenuBarView` (or rely on shared singleton) |
| `Sources/AnyDoor/Views/MenuBarView.swift` | Render `UpdateBannerView` conditionally above the rows |
| `Sources/AnyDoor/Views/GeneralSettingsView.swift` | Add "关于与更新" section |
| `Makefile` | Add `release`, `release-dryrun`, `sparkle-tools` targets |
| `.gitignore` | Ignore `scripts/sparkle-bin/`, `scripts/release-archive/`, `dist/` |

---

## Phase 1 — Dependency and bundle plumbing

### Task 1: Add Sparkle SPM dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the dependency**

Edit `Package.swift` to add Sparkle as a dependency and as a target product:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AnyDoor",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(
            url: "https://github.com/riko2chen/AskForPermission.git",
            revision: "91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.2"
        ),
    ],
    targets: [
        .executableTarget(
            name: "AnyDoor",
            dependencies: [
                .product(name: "AskForPermission", package: "AskForPermission"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "AnyDoorTests",
            dependencies: ["AnyDoor"],
            resources: [.process("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Resolve and verify build**

Run: `swift package resolve && swift build`
Expected: build succeeds with Sparkle resolved at exactly `2.9.2`. `Package.resolved` updated.

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat(update): add Sparkle 2.9.2 SPM dependency"
```

---

### Task 2: Add Sparkle keys to Info.plist

**Files:**
- Modify: `Info.plist`

Use a placeholder EdDSA public key for now; Task 14 replaces it with the real key.

- [ ] **Step 1: Add the three keys**

Open `Info.plist` and insert these keys (anywhere inside the top-level `<dict>`):

```xml
<key>SUFeedURL</key>
<string>https://github.com/ZingerLittleBee/AnyDoor/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>PLACEHOLDER_REPLACE_WITH_GENERATE_KEYS_OUTPUT</string>
<key>SUEnableSystemProfiling</key>
<false/>
```

Intentionally omitted: `SUEnableAutomaticChecks` (preserves Sparkle's consent prompt), `SUEnableInstallerLauncherService` (default is correct for non-sandboxed apps).

- [ ] **Step 2: Validate plist**

Run: `plutil -lint Info.plist`
Expected: `Info.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add Info.plist
git commit -m "feat(update): add Sparkle feed URL and placeholder EdDSA key to Info.plist"
```

---

### Task 3: Update .gitignore for release artifacts

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: Append entries**

Append to `.gitignore`:

```
# Auto-update release artifacts
/dist/
/scripts/sparkle-bin/
/scripts/release-archive/
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: ignore release dist and Sparkle tool artifacts"
```

---

## Phase 2 — UpdateService core (TDD)

### Task 4: Define UpdaterAdapter protocol

**Files:**
- Create: `Sources/AnyDoor/Services/UpdaterAdapter.swift`

This protocol exists so tests can substitute a fake updater. Production wraps `SPUUpdater`.

- [ ] **Step 1: Write the file**

Create `Sources/AnyDoor/Services/UpdaterAdapter.swift`:

```swift
import Foundation

/// Abstracts `SPUUpdater` so `UpdateService` can be tested with a fake.
/// All conformers run on the main actor — Sparkle's APIs require it.
@MainActor
protocol UpdaterAdapter: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    /// Seconds between scheduled checks. Sparkle stores this in `SUUpdateCheckInterval`.
    var updateCheckInterval: TimeInterval { get set }
    var lastUpdateCheckDate: Date? { get }

    /// Show Sparkle's standard "checking…" UI; user-initiated.
    func checkForUpdates()
    /// Silent check; populates `UpdateService.availableVersion` via the delegate path.
    func checkForUpdatesInBackground()
}
```

- [ ] **Step 2: Verify compile**

Run: `swift build`
Expected: succeeds; no references to `UpdaterAdapter` yet so nothing else uses it.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/UpdaterAdapter.swift
git commit -m "feat(update): introduce UpdaterAdapter protocol for testability"
```

---

### Task 5: Write failing UpdateService tests

**Files:**
- Create: `Tests/AnyDoorTests/UpdateServiceTests.swift`

Drive the `UpdateService` design from tests. The fake adapter lives inside the test file to keep it isolated.

- [ ] **Step 1: Write the test file**

Create `Tests/AnyDoorTests/UpdateServiceTests.swift`:

```swift
import XCTest
@testable import AnyDoor

@MainActor
final class UpdateServiceTests: XCTestCase {

    func testAutomaticChecksTogglePersistsThroughAdapter() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.automaticChecksEnabled = false
        XCTAssertFalse(fake.automaticallyChecksForUpdates)

        service.automaticChecksEnabled = true
        XCTAssertTrue(fake.automaticallyChecksForUpdates)
    }

    func testCheckIntervalDaysMapsToSeconds() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.checkIntervalDays = 7
        XCTAssertEqual(fake.updateCheckInterval, 7 * 86_400, accuracy: 0.5)

        service.checkIntervalDays = 1
        XCTAssertEqual(fake.updateCheckInterval, 86_400, accuracy: 0.5)
    }

    func testCheckForUpdatesForwardsToAdapter() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.checkForUpdates()
        XCTAssertEqual(fake.checkForUpdatesCallCount, 1)
    }

    func testFoundUpdatePopulatesAvailableVersion() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.didFindUpdate(version: "1.2.0")
        XCTAssertEqual(service.availableVersion, "1.2.0")
    }

    func testSkippedVersionIsSuppressedFromBanner() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { "1.2.0" })

        service.didFindUpdate(version: "1.2.0")
        XCTAssertNil(service.availableVersion, "skipped version must not show banner")
    }

    func testNewerVersionAfterSkipStillSurfaces() {
        let fake = FakeUpdater()
        var skipped: String? = "1.2.0"
        let service = UpdateService(adapter: fake, skippedVersionProvider: { skipped })

        service.didFindUpdate(version: "1.2.1")
        XCTAssertEqual(service.availableVersion, "1.2.1")

        // After the user later skips 1.2.1 as well, the banner clears on next check.
        skipped = "1.2.1"
        service.didFindUpdate(version: "1.2.1")
        XCTAssertNil(service.availableVersion)
    }

    func testDismissBannerForThisSessionClearsAvailableVersion() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.didFindUpdate(version: "1.2.0")
        service.dismissBannerForThisSession()
        XCTAssertNil(service.availableVersion)
    }

    func testNoUpdateFoundClearsAvailableVersion() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.didFindUpdate(version: "1.2.0")
        service.didNotFindUpdate()
        XCTAssertNil(service.availableVersion)
    }
}

@MainActor
private final class FakeUpdater: UpdaterAdapter {
    var automaticallyChecksForUpdates: Bool = true
    var updateCheckInterval: TimeInterval = 86_400
    var lastUpdateCheckDate: Date? = nil
    var checkForUpdatesCallCount: Int = 0
    var checkForUpdatesInBackgroundCallCount: Int = 0

    func checkForUpdates() { checkForUpdatesCallCount += 1 }
    func checkForUpdatesInBackground() { checkForUpdatesInBackgroundCallCount += 1 }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateServiceTests`
Expected: FAIL — `UpdateService` type is undefined.

---

### Task 6: Implement UpdateService

**Files:**
- Create: `Sources/AnyDoor/Services/UpdateService.swift`

- [ ] **Step 1: Write the implementation**

Create `Sources/AnyDoor/Services/UpdateService.swift`:

```swift
import Foundation
import Observation

/// Façade between Sparkle and the SwiftUI views. Views never import Sparkle;
/// they read this type via `UpdateService.shared` or dependency injection.
///
/// Threading: every property and method runs on `@MainActor`. The injected
/// `UpdaterAdapter` is also `@MainActor`, matching `SPUUpdater`'s isolation.
@MainActor
@Observable
final class UpdateService {

    // MARK: - Public state

    private(set) var availableVersion: String? = nil
    private(set) var isCheckingForUpdate: Bool = false
    private(set) var lastCheckDate: Date? = nil

    var automaticChecksEnabled: Bool {
        get { adapter.automaticallyChecksForUpdates }
        set { adapter.automaticallyChecksForUpdates = newValue }
    }

    var checkIntervalDays: Int {
        get { max(1, Int(adapter.updateCheckInterval / 86_400)) }
        set { adapter.updateCheckInterval = TimeInterval(max(1, newValue)) * 86_400 }
    }

    // MARK: - Init

    /// Shared instance bound to the production `SPUUpdater` by `AppDelegate`.
    /// Tests build instances directly with a fake adapter.
    static let shared: UpdateService = UpdateService(
        adapter: NullUpdaterAdapter(),
        skippedVersionProvider: { UserDefaults.standard.string(forKey: "SUSkippedVersion") }
    )

    private var adapter: UpdaterAdapter
    private let skippedVersionProvider: () -> String?

    init(adapter: UpdaterAdapter, skippedVersionProvider: @escaping () -> String?) {
        self.adapter = adapter
        self.skippedVersionProvider = skippedVersionProvider
    }

    /// Swap in the real Sparkle adapter once `AppDelegate` has constructed the controller.
    func rebind(to adapter: UpdaterAdapter) {
        self.adapter = adapter
    }

    // MARK: - User-facing actions

    func checkForUpdates() {
        adapter.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        adapter.checkForUpdatesInBackground()
    }

    func dismissBannerForThisSession() {
        availableVersion = nil
    }

    // MARK: - Sparkle delegate fan-in

    /// Called from the Sparkle delegate when a candidate update is reported.
    func didFindUpdate(version: String) {
        if let skipped = skippedVersionProvider(), skipped == version {
            availableVersion = nil
        } else {
            availableVersion = version
        }
        lastCheckDate = Date()
    }

    func didNotFindUpdate() {
        availableVersion = nil
        lastCheckDate = Date()
    }

    func checkingStarted() {
        isCheckingForUpdate = true
    }

    func checkingFinished() {
        isCheckingForUpdate = false
    }
}

/// Stand-in used until `AppDelegate.applicationDidFinishLaunching` rebinds the real adapter.
/// Keeps the shared instance usable in previews and dev-mode (where the updater never starts).
@MainActor
private final class NullUpdaterAdapter: UpdaterAdapter {
    var automaticallyChecksForUpdates: Bool = false
    var updateCheckInterval: TimeInterval = 86_400
    var lastUpdateCheckDate: Date? = nil
    func checkForUpdates() {}
    func checkForUpdatesInBackground() {}
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `swift test --filter UpdateServiceTests`
Expected: PASS (8 tests, 0 failures)

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/UpdateService.swift Tests/AnyDoorTests/UpdateServiceTests.swift
git commit -m "feat(update): add UpdateService with skipped-version filter and unit tests"
```

---

### Task 7: Wire AppDelegate to Sparkle behind a dev-mode guard

**Files:**
- Modify: `Sources/AnyDoor/AppDelegate.swift`

- [ ] **Step 1: Add the Sparkle integration**

Add to the top of `Sources/AnyDoor/AppDelegate.swift`:

```swift
import Sparkle
```

Add these stored properties near the top of `AppDelegate` (next to `menuBarController`):

```swift
    private var updaterController: SPUStandardUpdaterController?
    private var updaterBridge: SparkleUpdaterBridge?
```

Append this `MainActor`-isolated bootstrap helper at the end of `applicationDidFinishLaunching(_:)` (after the existing menu-bar observer setup, just before the closing brace):

```swift
        bootstrapUpdater()
```

Add these new methods inside `AppDelegate` (anywhere convenient, e.g. just before `applicationWillTerminate`):

```swift
    @MainActor
    private func bootstrapUpdater() {
        guard shouldStartUpdater() else {
            // `swift run` and unit tests reach here: no SUFeedURL/SUPublicEDKey, no
            // installed bundle id. Sparkle would log noisy errors and could crash.
            return
        }

        let bridge = SparkleUpdaterBridge(service: UpdateService.shared)
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: bridge,
            userDriverDelegate: nil
        )
        UpdateService.shared.rebind(to: SparkleUpdaterAdapter(updater: controller.updater))
        updaterController = controller
        updaterBridge = bridge
    }

    private func shouldStartUpdater() -> Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let hasFeed = !((info["SUFeedURL"] as? String) ?? "").isEmpty
        let hasKey = !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
        let isInstalled = Bundle.main.bundleIdentifier == "dev.bybee.AnyDoor"
        let placeholderKey = (info["SUPublicEDKey"] as? String) == "PLACEHOLDER_REPLACE_WITH_GENERATE_KEYS_OUTPUT"
        return hasFeed && hasKey && isInstalled && !placeholderKey
    }
```

- [ ] **Step 2: Add the Sparkle-side adapter and delegate bridge**

Create `Sources/AnyDoor/Services/SparkleUpdaterBridge.swift`:

```swift
import Foundation
import Sparkle

/// Production conformance forwarding to a real `SPUUpdater`.
@MainActor
final class SparkleUpdaterAdapter: UpdaterAdapter {
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var updateCheckInterval: TimeInterval {
        get { updater.updateCheckInterval }
        set { updater.updateCheckInterval = newValue }
    }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    func checkForUpdates() { updater.checkForUpdates() }
    func checkForUpdatesInBackground() { updater.checkForUpdatesInBackground() }
}

/// Translates Sparkle delegate callbacks into `UpdateService` mutations. Kept
/// separate from `UpdateService` so the service has zero Sparkle imports.
final class SparkleUpdaterBridge: NSObject, SPUUpdaterDelegate {
    private let service: UpdateService

    init(service: UpdateService) {
        self.service = service
        super.init()
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in service.didFindUpdate(version: version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in service.didNotFindUpdate() }
    }

    nonisolated func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        // No-op; here for future telemetry.
    }
}
```

- [ ] **Step 3: Build and run unit tests**

Run: `swift build`
Expected: succeeds.

Run: `swift test --filter UpdateServiceTests`
Expected: PASS (still 8 tests).

- [ ] **Step 4: Verify dev mode is a no-op**

Run: `swift run AnyDoor` and check the log for the line "starting updater" or similar Sparkle-emitted messages. Expected: none — the guard short-circuits because `Bundle.main.bundleIdentifier` is not `dev.bybee.AnyDoor` under `swift run`.

Quit the app (Cmd-Q from the status item menu) before continuing.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/AppDelegate.swift Sources/AnyDoor/Services/SparkleUpdaterBridge.swift
git commit -m "feat(update): bootstrap Sparkle updater behind dev-mode guard"
```

---

## Phase 3 — UI integration

### Task 8: Build UpdateBannerView

**Files:**
- Create: `Sources/AnyDoor/Views/UpdateBannerView.swift`

- [ ] **Step 1: Write the view**

Create `Sources/AnyDoor/Views/UpdateBannerView.swift`:

```swift
import SwiftUI

/// Single row pinned above the menu-bar panel rows when a non-skipped update
/// is available. Calls `UpdateService` directly; nothing in this view knows
/// Sparkle exists.
struct UpdateBannerView: View {
    let version: String
    let onActivate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text("AnyDoor \(version) 可更新")
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button(action: onActivate) {
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("查看并安装更新")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("本次启动不再提醒")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.12))
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
    }
}

#Preview {
    UpdateBannerView(version: "1.2.0", onActivate: {}, onDismiss: {})
        .frame(width: 260)
        .padding()
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/UpdateBannerView.swift
git commit -m "feat(update): add UpdateBannerView for the menu-bar panel"
```

---

### Task 9: Integrate UpdateBannerView into MenuBarView

**Files:**
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift`

- [ ] **Step 1: Add the banner above the rows**

In `Sources/AnyDoor/Views/MenuBarView.swift`, just after the existing `@State private var panel = PanelStore.shared` line, add:

```swift
    @State private var updateService = UpdateService.shared
```

Inside the top-level `VStack(alignment: .leading, spacing: 4) { … }`, between the header `HStack { … }` block and the `GlassEffectContainer(spacing: 2) { … }` block, insert:

```swift
            if let version = updateService.availableVersion {
                UpdateBannerView(
                    version: version,
                    onActivate: {
                        updateService.checkForUpdates()
                    },
                    onDismiss: {
                        updateService.dismissBannerForThisSession()
                    }
                )
            }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/MenuBarView.swift
git commit -m "feat(update): render UpdateBannerView when an update is available"
```

---

### Task 10: Add the update section to GeneralSettingsView

**Files:**
- Modify: `Sources/AnyDoor/Views/GeneralSettingsView.swift`

- [ ] **Step 1: Add state and a new section**

In `Sources/AnyDoor/Views/GeneralSettingsView.swift`, add this state near the existing `@State` declarations at the top of `GeneralSettingsView`:

```swift
    @State private var updateService = UpdateService.shared
    @State private var checkInterval: CheckInterval = .daily
```

Add this enum at the very bottom of the file, outside the struct:

```swift
extension GeneralSettingsView {
    enum CheckInterval: Int, CaseIterable, Identifiable {
        case daily = 1
        case weekly = 7
        case manualOnly = 0

        var id: Int { rawValue }
        var label: String {
            switch self {
            case .daily: "每日"
            case .weekly: "每周"
            case .manualOnly: "仅手动"
            }
        }
    }
}
```

Append this new section after the existing `Section("权限")` block inside the `Form`:

```swift
            Section("关于与更新") {
                LabeledContent("当前版本") {
                    Text(Bundle.main.shortVersionString ?? "—")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Toggle("自动检查更新", isOn: Binding(
                    get: { updateService.automaticChecksEnabled },
                    set: { updateService.automaticChecksEnabled = $0 }
                ))

                Picker("检查频率", selection: $checkInterval) {
                    ForEach(CheckInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .disabled(!updateService.automaticChecksEnabled)
                .onChange(of: checkInterval) { _, new in
                    switch new {
                    case .daily: updateService.checkIntervalDays = 1
                    case .weekly: updateService.checkIntervalDays = 7
                    case .manualOnly: updateService.automaticChecksEnabled = false
                    }
                }

                LabeledContent("上次检查") {
                    Text(updateService.lastCheckDate?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                        .foregroundStyle(.secondary)
                }

                Button("立即检查更新…") {
                    updateService.checkForUpdates()
                }
            }
```

- [ ] **Step 2: Add the Bundle convenience**

Create `Sources/AnyDoor/Utilities/BundleVersion.swift`:

```swift
import Foundation

extension Bundle {
    /// `CFBundleShortVersionString`, e.g. `"1.2.0"`.
    var shortVersionString: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
```

- [ ] **Step 3: Build and run the app**

Run: `swift build`
Expected: succeeds.

Run: `swift run AnyDoor`, open Settings (status item → 设置), confirm the new "关于与更新" section renders: current version "1.0", an enabled toggle, a frequency picker, "上次检查 —", and a "立即检查更新…" button.

(The button does nothing visible in dev mode because the updater is short-circuited — that's expected.)

Quit the app before continuing.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/GeneralSettingsView.swift Sources/AnyDoor/Utilities/BundleVersion.swift
git commit -m "feat(update): add update section to General settings"
```

---

## Phase 4 — Release pipeline

### Task 11: Author CHANGELOG.md

**Files:**
- Create: `CHANGELOG.md`

- [ ] **Step 1: Write the file**

Create `CHANGELOG.md`:

```markdown
# Changelog

All notable changes to AnyDoor are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic
versioning.

## [Unreleased]

### Added

- Auto-update via Sparkle 2 with assets published to GitHub Releases.
- "关于与更新" section in General settings.
- Menu bar panel banner when a new version is available.

## [1.0.0] - 2026-05-23

- Initial release.
```

(Adjust the 1.0.0 date if your project's first release predates this.)

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: introduce CHANGELOG"
```

---

### Task 12: Author scripts/install-sparkle-tools.sh

**Files:**
- Create: `scripts/install-sparkle-tools.sh`

- [ ] **Step 1: Make the scripts directory if missing**

Run: `mkdir -p scripts`

- [ ] **Step 2: Write the script**

Create `scripts/install-sparkle-tools.sh`:

```bash
#!/usr/bin/env bash
# Download Sparkle's release tarball and extract sign_update + generate_appcast
# into scripts/sparkle-bin/. Idempotent: skips when the pinned version is already present.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <sparkle-version>" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$REPO_ROOT/scripts/sparkle-bin"
STAMP_FILE="$BIN_DIR/.version"

if [[ -f "$STAMP_FILE" ]] && [[ "$(cat "$STAMP_FILE")" == "$VERSION" ]]; then
  echo "sparkle tools already installed at $VERSION"
  exit 0
fi

mkdir -p "$BIN_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
echo "Downloading $URL"
curl -fL "$URL" -o "$TMP_DIR/sparkle.tar.xz"
tar -xf "$TMP_DIR/sparkle.tar.xz" -C "$TMP_DIR"

# Sparkle distributes its CLI tools under bin/.
cp "$TMP_DIR/bin/sign_update" "$BIN_DIR/sign_update"
cp "$TMP_DIR/bin/generate_appcast" "$BIN_DIR/generate_appcast"
cp "$TMP_DIR/bin/generate_keys" "$BIN_DIR/generate_keys" 2>/dev/null || true
chmod +x "$BIN_DIR"/*

echo "$VERSION" > "$STAMP_FILE"
echo "Installed sparkle tools $VERSION → $BIN_DIR"
```

- [ ] **Step 3: Make executable and dry-run**

Run: `chmod +x scripts/install-sparkle-tools.sh && scripts/install-sparkle-tools.sh 2.9.2`
Expected: downloads and extracts `sign_update`, `generate_appcast`, `generate_keys` into `scripts/sparkle-bin/`; prints "Installed sparkle tools 2.9.2".

Run: `ls scripts/sparkle-bin/`
Expected: `.version  generate_appcast  generate_keys  sign_update`

- [ ] **Step 4: Commit**

```bash
git add scripts/install-sparkle-tools.sh
git commit -m "chore(release): script to install pinned Sparkle CLI tools"
```

---

### Task 13: Author scripts/bump-version.sh

**Files:**
- Create: `scripts/bump-version.sh`

- [ ] **Step 1: Write the script**

Create `scripts/bump-version.sh`:

```bash
#!/usr/bin/env bash
# Resolve the next version and write it into Info.plist.
# Usage:
#   scripts/bump-version.sh            # patch+1
#   scripts/bump-version.sh 1.2.3      # explicit
# Prints the resolved version to stdout (everything else goes to stderr).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$REPO_ROOT/Info.plist"

requested="${1:-}"

current="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"

if [[ -z "$requested" ]]; then
  # patch+1
  IFS='.' read -r major minor patch <<<"$current"
  if [[ -z "${patch:-}" ]]; then
    echo "current CFBundleShortVersionString '$current' is not MAJOR.MINOR.PATCH" >&2
    exit 1
  fi
  next="${major}.${minor}.$((patch + 1))"
else
  if ! [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION '$requested' must be strict semver MAJOR.MINOR.PATCH (no pre-release suffixes)" >&2
    exit 1
  fi
  next="$requested"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next" "$PLIST"

echo "$next"
```

- [ ] **Step 2: Make executable and smoke test**

Run: `chmod +x scripts/bump-version.sh`

Verify the dry behaviour without committing:

```bash
cp Info.plist /tmp/Info.plist.bak
scripts/bump-version.sh 9.9.9
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist
# Expected: 9.9.9
cp /tmp/Info.plist.bak Info.plist
```

- [ ] **Step 3: Commit**

```bash
git add scripts/bump-version.sh
git commit -m "chore(release): script to bump and validate the version"
```

---

### Task 14: Author scripts/release.sh

**Files:**
- Create: `scripts/release.sh`

This is the only large shell file in the plan. Steps mirror §6.3 of the spec.

- [ ] **Step 1: Write the script**

Create `scripts/release.sh`:

```bash
#!/usr/bin/env bash
# End-to-end release driver. Mirrors §6.3 of the design spec.
# Usage:
#   scripts/release.sh                     # patch+1
#   scripts/release.sh 1.2.3               # explicit version
#   DRYRUN=1 scripts/release.sh 1.2.3      # stop after appcast generation

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DRYRUN="${DRYRUN:-0}"
REQUESTED_VERSION="${1:-}"

# Configuration knobs
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AnyDoor-Notary}"
TEAM_ID="${TEAM_ID:-}"  # only required when SIGNING_IDENTITY is ambiguous
REPO_URL="${REPO_URL:-https://github.com/ZingerLittleBee/AnyDoor}"
DOWNLOAD_URL_BASE="$REPO_URL/releases/download"

DIST="$REPO_ROOT/dist"
ARCHIVE="$REPO_ROOT/scripts/release-archive"
SPARKLE_BIN="$REPO_ROOT/scripts/sparkle-bin"

log() { printf '\033[1;34m▸\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Preflight ---------------------------------------------------------
log "Preflight checks"

[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit or stash first"
[[ "$(git branch --show-current)" == "main" ]] || die "must release from main"

git fetch origin --tags --quiet
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "local main is not in sync with origin/main"

grep -q '^## \[Unreleased\]' CHANGELOG.md || die "CHANGELOG.md is missing '## [Unreleased]' section"
notes_body="$(awk '/^## \[Unreleased\]/{flag=1; next} /^## \[/{flag=0} flag' CHANGELOG.md | sed '/./,$!d')"
[[ -n "$notes_body" ]] || die "'## [Unreleased]' section is empty — write release notes first"

security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" \
  || die "no codesigning identity matching '$SIGNING_IDENTITY' in login keychain"

for bin in sign_update generate_appcast; do
  [[ -x "$SPARKLE_BIN/$bin" ]] || die "missing $SPARKLE_BIN/$bin — run 'make sparkle-tools'"
done

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool keychain profile '$NOTARY_PROFILE' not configured"

gh auth status -h github.com >/dev/null 2>&1 || die "gh CLI is not authenticated"

# --- 2. Resolve version --------------------------------------------------
log "Resolve version"
VER="$(scripts/bump-version.sh "$REQUESTED_VERSION")"
log "VERSION → $VER"

git rev-parse "v$VER" >/dev/null 2>&1 && die "tag v$VER already exists locally"
git ls-remote --tags origin "v$VER" | grep -q . && die "tag v$VER already exists on origin"

# bump-version.sh wrote Info.plist. Stage the change in the working tree but
# don't commit yet; the commit happens after all artifacts are produced.

# --- 3. Mutate CHANGELOG and emit release notes --------------------------
log "Update CHANGELOG"
TODAY="$(date +%Y-%m-%d)"
python3 - "$VER" "$TODAY" <<'PY'
import re, sys, pathlib
ver, today = sys.argv[1], sys.argv[2]
path = pathlib.Path("CHANGELOG.md")
text = path.read_text()
text = re.sub(r"^## \[Unreleased\]", f"## [Unreleased]\n\n## [{ver}] - {today}", text, count=1, flags=re.MULTILINE)
path.write_text(text)
PY

mkdir -p "$DIST"
awk -v ver="$VER" '
  $0 == "## ["ver"] - "strftime("%Y-%m-%d"){flag=1; next}
  /^## \[/ && flag {exit}
  flag {print}
' CHANGELOG.md | sed '/./,$!d' > "$DIST/release-notes.md"
[[ -s "$DIST/release-notes.md" ]] || die "failed to extract release notes for $VER"

# --- 4. Build ------------------------------------------------------------
log "swift build -c release"
swift build -c release

# --- 5. Assemble .app ----------------------------------------------------
log "Assemble dist/AnyDoor.app"
APP="$DIST/AnyDoor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp ".build/release/AnyDoor" "$APP/Contents/MacOS/AnyDoor"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"

BIN_PATH="$(swift build --show-bin-path -c release)"
SPARKLE_FW=""
for candidate in \
  "$BIN_PATH/Sparkle.framework" \
  "$BIN_PATH/PackageFrameworks/Sparkle.framework" \
  "$BIN_PATH/../PackageFrameworks/Sparkle.framework"; do
  if [[ -d "$candidate" ]]; then
    SPARKLE_FW="$candidate"
    break
  fi
done
[[ -n "$SPARKLE_FW" ]] || die "could not find Sparkle.framework under $BIN_PATH"
log "Sparkle.framework → $SPARKLE_FW"
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

# --- 6. Codesign (depth-first) -------------------------------------------
log "Codesign Sparkle helpers (depth-first)"
FW_ROOT="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
# XPC services first, then helper apps, then framework, then main binary, then bundle.
while IFS= read -r -d '' xpc; do
  codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$xpc"
done < <(find "$FW_ROOT/XPCServices" -type d -name '*.xpc' -print0 2>/dev/null || true)

for helper in "$FW_ROOT/Autoupdate.app" "$FW_ROOT/Updater.app"; do
  [[ -d "$helper" ]] && codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$helper"
done

codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/AnyDoor"
codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"

log "Verify codesign"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 7. Notarize .app ----------------------------------------------------
log "Notarize .app"
ditto -c -k --keepParent "$APP" "$DIST/_notary.zip"
xcrun notarytool submit "$DIST/_notary.zip" --keychain-profile "$NOTARY_PROFILE" --wait
rm "$DIST/_notary.zip"
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP"

# --- 8. Package final assets --------------------------------------------
ZIP="$DIST/AnyDoor-$VER.zip"
DMG="$DIST/AnyDoor-$VER.dmg"
log "Package $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

log "Package $DMG"
rm -f "$DMG"
if ! command -v create-dmg >/dev/null 2>&1; then
  die "create-dmg not found in PATH (brew install create-dmg)"
fi
create-dmg \
  --volname "AnyDoor $VER" \
  --window-size 540 320 \
  --icon-size 96 \
  --app-drop-link 380 170 \
  "$DMG" \
  "$APP"
codesign --force --sign "$SIGNING_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# --- 9. Sparkle EdDSA sign ----------------------------------------------
log "Sparkle EdDSA sign"
ED_SIGNATURE_OUTPUT="$("$SPARKLE_BIN/sign_update" "$ZIP")"
log "→ $ED_SIGNATURE_OUTPUT"

# --- 10. Generate appcast -----------------------------------------------
log "Generate appcast.xml"
mkdir -p "$ARCHIVE"
cp "$ZIP" "$ARCHIVE/"
"$SPARKLE_BIN/generate_appcast" "$ARCHIVE" \
  --maximum-deltas 0 \
  --download-url-prefix "$DOWNLOAD_URL_BASE/" \
  --link "$REPO_URL"

APPCAST="$ARCHIVE/appcast.xml"
[[ -f "$APPCAST" ]] || die "generate_appcast did not produce $APPCAST"

# generate_appcast emits enclosure URLs like
#   <DOWNLOAD_URL_BASE>/<filename>
# We need <DOWNLOAD_URL_BASE>/v<version>/<filename> so each release's zip
# is fetched from its own version-tagged release page (not /latest/).
python3 - "$APPCAST" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
def fix(m):
    url = m.group(1)
    fname = url.rsplit("/", 1)[-1]
    # AnyDoor-1.2.3.zip → v1.2.3
    ver_match = re.search(r"AnyDoor-(\d+\.\d+\.\d+)\.zip$", fname)
    if not ver_match:
        return m.group(0)
    ver = ver_match.group(1)
    base = url.rsplit("/", 1)[0]
    return f'url="{base}/v{ver}/{fname}"'
text = re.sub(r'url="([^"]+AnyDoor-\d+\.\d+\.\d+\.zip)"', fix, text)
path.write_text(text)
PY

# Inject release notes into this version's <description><![CDATA[…]]>
python3 - "$APPCAST" "$VER" "$DIST/release-notes.md" <<'PY'
import sys, pathlib, re
appcast = pathlib.Path(sys.argv[1])
ver = sys.argv[2]
notes = pathlib.Path(sys.argv[3]).read_text().strip()
text = appcast.read_text()
# Locate the item whose sparkle:shortVersionString matches ver, then either
# replace existing <description> or insert one before <enclosure>.
item_re = re.compile(
    r'(<item>.*?<sparkle:shortVersionString>' + re.escape(ver) +
    r'</sparkle:shortVersionString>.*?)(<enclosure )',
    re.DOTALL,
)
def repl(m):
    block = m.group(1)
    block = re.sub(r'<description>.*?</description>', '', block, flags=re.DOTALL)
    cdata = f'<description><![CDATA[\n{notes}\n]]></description>\n'
    return block + cdata + m.group(2)
new_text, count = item_re.subn(repl, text, count=1)
if count == 0:
    raise SystemExit(f"could not find item for version {ver} in appcast")
appcast.write_text(new_text)
PY

xmllint --noout "$APPCAST"

URL_RE='^https://github\.com/ZingerLittleBee/AnyDoor/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/AnyDoor-[0-9]+\.[0-9]+\.[0-9]+\.zip$'
while IFS= read -r url; do
  [[ "$url" =~ $URL_RE ]] || die "appcast enclosure URL fails version-pinning regex: $url"
done < <(grep -oE 'url="[^"]+AnyDoor-[^"]+\.zip"' "$APPCAST" | sed 's/^url="\(.*\)"$/\1/')

cp "$APPCAST" "$REPO_ROOT/appcast.xml"

if [[ "$DRYRUN" == "1" ]]; then
  log "Dry run: stopping before git commit / push / release."
  exit 0
fi

# --- 11. Git commit + tag ------------------------------------------------
log "git commit + tag"
git add Info.plist CHANGELOG.md appcast.xml
git commit -m "release: v$VER"
git tag "v$VER"

# --- 12. Push --------------------------------------------------------
log "git push (commit + tag)"
git push origin main
git push origin "v$VER"

# --- 13. Create draft release, upload assets, publish ------------------
log "gh release create v$VER (draft)"
gh release create "v$VER" \
  --draft \
  --title "AnyDoor $VER" \
  --notes-file "$DIST/release-notes.md" \
  "$DMG" "$ZIP" "$APPCAST"

log "Publish release"
gh release edit "v$VER" --draft=false

log "Done. v$VER published at $REPO_URL/releases/tag/v$VER"
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/release.sh`

- [ ] **Step 3: Commit (no run yet)**

```bash
git add scripts/release.sh
git commit -m "chore(release): end-to-end release driver script"
```

---

### Task 15: Add Makefile targets

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Edit the Makefile**

Append to `Makefile`:

```make
# ----- Release pipeline --------------------------------------------------

# Pin SPM dependency and downloaded CLI tools to the same Sparkle release.
SPARKLE_VERSION := 2.9.2

sparkle-tools:
	@./scripts/install-sparkle-tools.sh $(SPARKLE_VERSION)

release: sparkle-tools
	@./scripts/release.sh $(VERSION)

release-dryrun: sparkle-tools
	@DRYRUN=1 ./scripts/release.sh $(VERSION)
```

- [ ] **Step 2: Commit**

```bash
git add Makefile
git commit -m "chore(release): expose release targets via Makefile"
```

---

## Phase 5 — Key material and end-to-end validation

These tasks require one-time manual operations and producing real signed artifacts. They are designed to be run by the developer who owns the Developer ID; an agentic worker should pause here, surface the steps, and wait for the human to drive them.

### Task 16: Generate EdDSA keys and update Info.plist

**Files:**
- Modify: `Info.plist`

- [ ] **Step 1: Run generate_keys**

Run: `scripts/sparkle-bin/generate_keys`

The first run prints two values:
- A base64 public key (also echoed to stdout)
- A note that the private key has been stored in the keychain under "https://sparkle-project.org"

- [ ] **Step 2: Replace the placeholder**

Open `Info.plist` and replace the `PLACEHOLDER_REPLACE_WITH_GENERATE_KEYS_OUTPUT` value of `SUPublicEDKey` with the printed public key.

Validate: `plutil -lint Info.plist`
Expected: `Info.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add Info.plist
git commit -m "feat(update): set real Sparkle EdDSA public key"
```

---

### Task 17: One-time notarytool credentials and create-dmg

These set up the developer machine for the first release. Skip steps you've already done previously.

- [ ] **Step 1: Install create-dmg if missing**

Run: `command -v create-dmg || brew install create-dmg`

- [ ] **Step 2: Register notarytool keychain profile**

Run:
```bash
xcrun notarytool store-credentials "AnyDoor-Notary" \
    --apple-id "<your apple id>" \
    --team-id  "<your team id>" \
    --password "<app-specific password>"
```

Verify: `xcrun notarytool history --keychain-profile AnyDoor-Notary`
Expected: succeeds (may show no entries on a fresh setup, but must not error).

- [ ] **Step 3: Confirm signing identity**

Run: `security find-identity -v -p codesigning`
Expected: at least one line matching `Developer ID Application: ...`. If absent, install your `.p12` via Xcode → Settings → Accounts.

(No commit; these are environment changes.)

---

### Task 18: Dry-run release

This validates the entire release pipeline without touching git or `gh`.

- [ ] **Step 1: Run dry-run**

Run: `make release-dryrun VERSION=1.0.1`
Expected: completes through appcast generation; prints "Dry run: stopping before git commit / push / release."; produces `dist/AnyDoor.app`, `dist/AnyDoor-1.0.1.zip`, `dist/AnyDoor-1.0.1.dmg`, and `appcast.xml` at the repo root.

- [ ] **Step 2: Verify the zip with sign_update**

Run: `scripts/sparkle-bin/sign_update --verify dist/AnyDoor-1.0.1.zip`
Expected: prints "OK" (or equivalent success) with no errors.

- [ ] **Step 3: Verify Gatekeeper acceptance**

Run: `spctl -a -t exec -vv dist/AnyDoor.app`
Expected: `accepted` and `source=Notarized Developer ID`.

- [ ] **Step 4: Verify appcast enclosure URLs**

Run: `grep enclosure appcast.xml`
Expected: every URL matches `https://github.com/ZingerLittleBee/AnyDoor/releases/download/v1.0.1/AnyDoor-1.0.1.zip`.

- [ ] **Step 5: Roll back the Info.plist version bump**

Because dry-run does not commit, `Info.plist` and `CHANGELOG.md` are now dirty. Restore them:

```bash
git checkout -- Info.plist CHANGELOG.md
rm appcast.xml
```

- [ ] **Step 6: Optional cleanup**

```bash
rm -rf dist/
```

---

### Task 19: Cut the first real release

- [ ] **Step 1: Choose the first release version**

For the first auto-update-enabled release, pick a version higher than the placeholder `1.0`. `1.1.0` is reasonable; this plan assumes it.

- [ ] **Step 2: Ensure CHANGELOG.md `[Unreleased]` section is non-empty**

The Phase 4 task already populated it with bullets. Adjust if needed.

- [ ] **Step 3: Run the release**

Run: `make release VERSION=1.1.0`
Expected: completes through step 13; prints "Done. v1.1.0 published at https://github.com/.../releases/tag/v1.1.0".

- [ ] **Step 4: Run the §9.1 manual e2e checklist**

Refer to `docs/superpowers/specs/2026-05-23-auto-update-design.md` §9.1. Document the outcome (pass/fail) inline as comments in the spec PR or as a separate test report.

---

## Post-implementation

- [ ] **Step 1: Merge feat/auto-update**

After §9.1 passes, open a PR from `feat/auto-update` → `main` and merge.

- [ ] **Step 2: Verify CLAUDE.md doesn't need updating**

The auto-update flow does not affect the existing architecture invariants. Skip unless something landed differently than designed.

---

## Notes on alternative execution

- **TDD discipline is partial here.** `UpdateService` is TDD'd (Tasks 5–6); the views and shell scripts are not, because their behavior is only meaningful in integration. The §9.1 manual checklist is the integration-test surface for the shell pipeline. Do not skip it.
- **One-shot signing/notarization secrets** (Developer ID `.p12`, EdDSA private key, notarytool profile) are intentionally **not** scripted. They are set up once per developer machine in Tasks 16–17.
- **Future delta updates** require setting `--maximum-deltas` > 0 in `generate_appcast` and uploading the `.delta` files alongside the `.zip`s. Out of scope here.
