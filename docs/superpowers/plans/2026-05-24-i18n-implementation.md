# i18n (zh-Hans + en) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add runtime-switchable Simplified Chinese / English localization to AnyDoor with instant in-app language override, built on Apple's String Catalog.

**Architecture:** Single `Localizable.xcstrings` in `Sources/AnyDoor/Resources/`. A `@Observable @MainActor` `LocalizationManager` singleton owns the active `LanguagePreference` (system / zh / en) via `@AppStorage`, resolves an `effectiveLocale` and a language-specific sub-`Bundle` of `Bundle.module`. All UI strings go through a typed `L10n.Key` enum and a free `L(_:)` function / `LocalizedText` SwiftUI view that reads from the manager — so changing preference triggers instant re-render. App-side strings only; documentation, Sparkle, and brand name are out of scope. See spec: `docs/superpowers/specs/2026-05-24-i18n-design.md`.

**Tech Stack:** Swift 6.2 strict concurrency, SwiftPM, SwiftUI, `String(localized:bundle:locale:)`, `@AppStorage`, XCTest.

---

## How to migrate one Swift file (recipe used by Tasks 7–13)

Apply this mechanically when a task says "migrate file X":

1. For every Chinese string literal in the file, pick (or add) an `L10n.Key` case in `Utilities/L10n.swift`. Naming follows the convention in the spec (`<namespace>.<verbNoun>`).
2. For each new key, add the source-language (zh-Hans) translation to `Resources/Localizable.xcstrings` and the English translation. xcstrings is JSON — see Task 12 for the exact shape.
3. Replace the literal:
   - **`Text("中文")`** → `LocalizedText(.theKey)`
   - **`"中文"` as a parameter / interpolation** → `L(.theKey)` or `L(.theKey, arg1, arg2)` with positional `%@` / `%lld` specifiers
   - **`Label("中文", systemImage: …)`** → `Label { LocalizedText(.theKey) } icon: { Image(systemName: …) }`
   - **`Button("中文") { … }`** → `Button { … } label: { LocalizedText(.theKey) }`
   - **`Section("中文")` / `Section { … } header: { Text("中文") }`** → `Section { … } header: { LocalizedText(.theKey) }`
   - **`Toggle("中文", isOn: …)`** → `Toggle(isOn: …) { LocalizedText(.theKey) }`
   - **`Picker("中文", selection: …)`** → keep `Picker(selection: …) { … } label: { LocalizedText(.theKey) }`
   - **`.help("中文")`** → `.help(L(.theKey))`
   - **`.accessibilityLabel("中文")`** → `.accessibilityLabel(L(.theKey))`
   - **NSAlert `.messageText` / `.informativeText`** → assign `L(.theKey)`
4. Build (`swift build`) before commit; commit the file change + the catalog/key additions together.

---

## Task 1: Add String Catalog scaffolding to Package.swift

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AnyDoor/Resources/Localizable.xcstrings`

- [ ] **Step 1.1: Add `defaultLocalization` and resources to the executable target**

Edit `Package.swift`. Add `defaultLocalization: "en"` to the `Package(...)` initializer (before `platforms:`), and add `resources: [.process("Resources")]` to the `AnyDoor` executable target.

```swift
let package = Package(
    name: "AnyDoor",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
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
            resources: [
                .process("Resources"),
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

- [ ] **Step 1.2: Create the empty String Catalog with one demo key**

Create `Sources/AnyDoor/Resources/Localizable.xcstrings` with this exact content (JSON):

```json
{
  "sourceLanguage" : "en",
  "strings" : {
    "demo.hello" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "Hello"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "你好"
          }
        }
      }
    }
  },
  "version" : "1.0"
}
```

- [ ] **Step 1.3: Build to confirm SPM accepts the resource**

Run: `swift build`
Expected: build succeeds, no warning about missing localizations.

- [ ] **Step 1.4: Commit**

```bash
git add Package.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "build: enable String Catalog resources (en default, zh-Hans)"
```

---

## Task 2: Implement `LocalizationManager`

**Files:**
- Create: `Sources/AnyDoor/Services/LocalizationManager.swift`
- Create: `Tests/AnyDoorTests/LocalizationManagerTests.swift`

- [ ] **Step 2.1: Write the failing test**

Create `Tests/AnyDoorTests/LocalizationManagerTests.swift`:

```swift
import XCTest
@testable import AnyDoor

@MainActor
final class LocalizationManagerTests: XCTestCase {
    private let defaultsKey = "dev.bybee.AnyDoor.language"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        super.tearDown()
    }

    func test_defaultPreferenceIsSystem() {
        let manager = LocalizationManager()
        XCTAssertEqual(manager.preference, .system)
    }

    func test_settingPreferencePersists() {
        let manager = LocalizationManager()
        manager.preference = .zh
        let reloaded = LocalizationManager()
        XCTAssertEqual(reloaded.preference, .zh)
    }

    func test_zhPreferenceResolvesToZhHans() {
        let manager = LocalizationManager()
        manager.preference = .zh
        XCTAssertEqual(manager.effectiveLocale.identifier, "zh-Hans")
    }

    func test_enPreferenceResolvesToEn() {
        let manager = LocalizationManager()
        manager.preference = .en
        XCTAssertEqual(manager.effectiveLocale.identifier, "en")
    }

    func test_systemFallsBackToEnForUnsupportedLanguage() {
        let manager = LocalizationManager(preferredLanguagesProvider: { ["ja"] })
        XCTAssertEqual(manager.effectiveLocale.identifier, "en")
    }

    func test_systemResolvesZhPreferredLanguage() {
        let manager = LocalizationManager(preferredLanguagesProvider: { ["zh-Hans-CN", "en"] })
        XCTAssertEqual(manager.effectiveLocale.identifier, "zh-Hans")
    }

    func test_bundleChangesWhenPreferenceChanges() {
        let manager = LocalizationManager()
        manager.preference = .en
        let enBundle = manager.bundle
        manager.preference = .zh
        let zhBundle = manager.bundle
        XCTAssertNotEqual(enBundle.bundlePath, zhBundle.bundlePath)
    }
}
```

- [ ] **Step 2.2: Run the failing test**

Run: `swift test --filter LocalizationManagerTests`
Expected: FAIL ("cannot find 'LocalizationManager' in scope").

- [ ] **Step 2.3: Implement `LocalizationManager`**

Create `Sources/AnyDoor/Services/LocalizationManager.swift`:

```swift
import Foundation
import Observation

/// User-facing language preference. `.system` follows macOS preferred languages
/// (resolved against the app's supported set); the others force a specific locale.
enum LanguagePreference: String, CaseIterable, Sendable {
    case system
    case zh
    case en
}

/// Resolves the active locale + resource bundle so all UI strings can be
/// re-localized without a relaunch. SwiftUI views observe this object to
/// re-render when the preference changes.
@MainActor
@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()

    static let defaultsKey = "dev.bybee.AnyDoor.language"
    static let supportedLocaleIdentifiers: [String] = ["zh-Hans", "en"]

    private let preferredLanguagesProvider: @Sendable () -> [String]
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        preferredLanguagesProvider: @escaping @Sendable () -> [String] = { Locale.preferredLanguages }
    ) {
        self.defaults = defaults
        self.preferredLanguagesProvider = preferredLanguagesProvider
        if let raw = defaults.string(forKey: Self.defaultsKey),
           let parsed = LanguagePreference(rawValue: raw) {
            self._preference = parsed
        } else {
            self._preference = .system
        }
    }

    private var _preference: LanguagePreference

    var preference: LanguagePreference {
        get { _preference }
        set {
            guard newValue != _preference else { return }
            _preference = newValue
            defaults.set(newValue.rawValue, forKey: Self.defaultsKey)
        }
    }

    /// The resolved `Locale` to apply via `String(localized:locale:)` and SwiftUI's `\.locale`.
    var effectiveLocale: Locale {
        Locale(identifier: resolvedLocaleIdentifier())
    }

    /// The resource bundle scoped to `effectiveLocale`. Strings looked up via
    /// `String(localized:bundle:locale:)` against this bundle re-resolve on
    /// preference change, bypassing the process-locked `Bundle.main` lookup.
    var bundle: Bundle {
        let id = resolvedLocaleIdentifier()
        if let path = Bundle.module.path(forResource: id, ofType: "lproj"),
           let lprojBundle = Bundle(path: path) {
            return lprojBundle
        }
        // Fall back to the module bundle (its development region) if the
        // .lproj isn't on disk yet — for example before any strings ship.
        return Bundle.module
    }

    private func resolvedLocaleIdentifier() -> String {
        switch _preference {
        case .zh: return "zh-Hans"
        case .en: return "en"
        case .system:
            for code in preferredLanguagesProvider() {
                if let match = Self.matchSupportedLocale(for: code) {
                    return match
                }
            }
            return "en"
        }
    }

    static func matchSupportedLocale(for languageCode: String) -> String? {
        let normalized = languageCode.lowercased()
        if normalized.hasPrefix("zh") { return "zh-Hans" }
        if normalized.hasPrefix("en") { return "en" }
        return nil
    }
}
```

- [ ] **Step 2.4: Run tests and verify pass**

Run: `swift test --filter LocalizationManagerTests`
Expected: 7 tests pass. `test_bundleChangesWhenPreferenceChanges` may currently see the same fallback `Bundle.module` if `.lproj` folders aren't built yet — if it fails, mark it `XCTSkip` with a comment "re-enable after Task 12 populates lproj resources" and proceed.

- [ ] **Step 2.5: Commit**

```bash
git add Sources/AnyDoor/Services/LocalizationManager.swift Tests/AnyDoorTests/LocalizationManagerTests.swift
git commit -m "feat(i18n): add LocalizationManager with preference + locale resolution"
```

---

## Task 3: Implement `L10n.Key` namespace and view helpers

**Files:**
- Create: `Sources/AnyDoor/Utilities/L10n.swift`

- [ ] **Step 3.1: Create the file with an empty key enum and the helpers**

Create `Sources/AnyDoor/Utilities/L10n.swift`:

```swift
import SwiftUI

/// Type-safe namespace for every translatable UI string. Keys are dot-separated
/// to mirror the structure in `Localizable.xcstrings`. Cases are added by
/// migration tasks; the catalog must contain a matching entry for each case.
enum L10n {
    enum Key: String, CaseIterable, Sendable {
        case demoHello = "demo.hello"
        // Migration tasks append cases here. Keep alphabetical by raw value.
    }
}

/// Resolves a translation for `key` against the active `LocalizationManager`.
/// Use this for non-View strings (NSAlert messages, .help / .accessibilityLabel
/// modifiers, string interpolation). For Text-in-views prefer `LocalizedText`
/// so the view re-renders when the preference changes.
@MainActor
func L(_ key: L10n.Key, _ args: CVarArg...) -> String {
    let manager = LocalizationManager.shared
    let template = NSLocalizedString(
        key.rawValue,
        tableName: nil,
        bundle: manager.bundle,
        value: key.rawValue,
        comment: ""
    )
    if args.isEmpty {
        return template
    }
    return String(format: template, locale: manager.effectiveLocale, arguments: args)
}

/// SwiftUI Text wrapper that re-renders on `LocalizationManager` changes.
/// Replaces raw `Text("中文")` everywhere in the view tree.
@MainActor
struct LocalizedText: View {
    @Environment(LocalizationManager.self) private var manager
    let key: L10n.Key

    init(_ key: L10n.Key) {
        self.key = key
    }

    var body: some View {
        // Reading manager.preference establishes a dependency so SwiftUI
        // re-renders this view when the user changes language.
        _ = manager.preference
        return Text(L(key))
    }
}
```

- [ ] **Step 3.2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 3.3: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift
git commit -m "feat(i18n): add L10n.Key namespace + L() / LocalizedText helpers"
```

---

## Task 4: Inject `LocalizationManager` into the SwiftUI environment

**Files:**
- Modify: `Sources/AnyDoor/AnyDoor.swift`
- Modify: `Sources/AnyDoor/AppDelegate.swift`
- Modify: `Sources/AnyDoor/Services/MenuBarController.swift` (around lines 17, 59–67 — `NSHostingView` setup)

- [ ] **Step 4.1: Make the manager available from `AppDelegate`**

Edit `Sources/AnyDoor/AppDelegate.swift`. Add a stored property after `let modelContainer: ModelContainer`:

```swift
let localizationManager = LocalizationManager.shared
```

- [ ] **Step 4.2: Inject into the Settings scene**

Edit `Sources/AnyDoor/AnyDoor.swift`:

```swift
import SwiftUI
import SwiftData

@main
struct AnyDoorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .modelContainer(appDelegate.modelContainer)
                .environment(appDelegate.localizationManager)
                .environment(\.locale, appDelegate.localizationManager.effectiveLocale)
        }
    }
}
```

- [ ] **Step 4.3: Inject into the menu bar panel**

Edit `Sources/AnyDoor/Services/MenuBarController.swift`. Locate the `NSHostingView` construction (around line 59) and modify the root view:

```swift
let hostingView = NSHostingView(
    rootView: AnyView(
        MenuBarView(onRequestClose: { [weak self] in self?.hidePanel() })
            .environment(LocalizationManager.shared)
            .environment(\.locale, LocalizationManager.shared.effectiveLocale)
    )
)
```

- [ ] **Step 4.4: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 4.5: Commit**

```bash
git add Sources/AnyDoor/AnyDoor.swift Sources/AnyDoor/AppDelegate.swift Sources/AnyDoor/Services/MenuBarController.swift
git commit -m "feat(i18n): inject LocalizationManager into menu bar + Settings scenes"
```

---

## Task 5: Add language picker to General Settings

**Files:**
- Modify: `Sources/AnyDoor/Views/GeneralSettingsView.swift`

The Picker is added now (before strings migration) so the toggle is wired end-to-end early. Its label and option titles use temporary `Text("…")` (Chinese) — they will be migrated in Task 9 along with the rest of this view.

- [ ] **Step 5.1: Add the language Section to `GeneralSettingsView`**

Edit `Sources/AnyDoor/Views/GeneralSettingsView.swift`. Add the manager environment and a new `Section` placed right after the "启动" section (before "菜单栏"):

```swift
@MainActor
struct GeneralSettingsView: View {
    @Environment(LocalizationManager.self) private var localization
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    // … existing state
```

Insert this Section after the launch-at-login Section's closing brace (after line 34 of the current file):

```swift
Section("语言") {
    @Bindable var localization = localization
    Picker(selection: Binding(
        get: { localization.preference },
        set: { localization.preference = $0 }
    )) {
        Text("跟随系统").tag(LanguagePreference.system)
        Text("中文").tag(LanguagePreference.zh)
        Text("English").tag(LanguagePreference.en)
    } label: {
        Text("界面语言")
    }
    .pickerStyle(.menu)
}
```

(`@Bindable` is harmless since `LocalizationManager` is `@Observable`; the manual `Binding` form is needed because `preference` has a custom setter.)

- [ ] **Step 5.2: Build and smoke-run**

Run: `swift build`
Expected: success.

Run: `swift run AnyDoor &` then open Settings → General. Verify the new "语言" section shows three options. Select each — no crash. Quit with Ctrl-C.

- [ ] **Step 5.3: Commit**

```bash
git add Sources/AnyDoor/Views/GeneralSettingsView.swift
git commit -m "feat(i18n): add language picker to General Settings"
```

---

## Task 6: Refactor models to expose `L10n.Key` instead of literal titles

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift` (line 45–70: `title`)
- Modify: `Sources/AnyDoor/Models/MenuBarIcon.swift` (lines 7–10, 22–37, 54–56)
- Modify: `Sources/AnyDoor/Services/PanelStore.swift` (line 71)
- Modify: `Sources/AnyDoor/Views/GeneralSettingsView.swift` (lines 142, 148)
- Modify: `Sources/AnyDoor/Models/PanelEntry.swift` (add `localizedTitle()` helper)

- [ ] **Step 6.1: Add `L10n.Key` cases for built-ins and menu bar icons**

Edit `Sources/AnyDoor/Utilities/L10n.swift`. Append these cases inside `L10n.Key` (keep alphabetical by raw value):

```swift
case builtinAppShortcuts = "builtin.appShortcuts"
case builtinAutoHideMenuBar = "builtin.autoHideMenuBar"
case builtinDarkMode = "builtin.darkMode"
case builtinDisplaySleep = "builtin.displaySleep"
case builtinEmptyTrash = "builtin.emptyTrash"
case builtinFlushDNS = "builtin.flushDNS"
case builtinHideDesktopIcons = "builtin.hideDesktopIcons"
case builtinHideDock = "builtin.hideDock"
case builtinKeepAwake = "builtin.keepAwake"
case builtinKeyboardLock = "builtin.keyboardLock"
case builtinLockScreen = "builtin.lockScreen"
case builtinMuteAudio = "builtin.muteAudio"
case builtinOCR = "builtin.ocr"
case builtinPickColor = "builtin.pickColor"
case builtinPortManager = "builtin.portManager"
case builtinQRCode = "builtin.qrcode"
case builtinRestartDock = "builtin.restartDock"
case builtinRestartFinder = "builtin.restartFinder"
case builtinRestartMenuBar = "builtin.restartMenuBar"
case builtinScreenshot = "builtin.screenshot"
case builtinShowHiddenFiles = "builtin.showHiddenFiles"
case builtinSystemSleep = "builtin.systemSleep"

case menubarIconAppConnected = "menubarIcon.appConnected"
case menubarIconBolt = "menubarIcon.bolt"
case menubarIconCommand = "menubarIcon.command"
case menubarIconConnectedPoints = "menubarIcon.connectedPoints"
case menubarIconCycle = "menubarIcon.cycle"
case menubarIconDoorLeft = "menubarIcon.doorLeft"
case menubarIconGlobe = "menubarIcon.globe"
case menubarIconGrid2x2 = "menubarIcon.grid2x2"
case menubarIconGrid3x3 = "menubarIcon.grid3x3"
case menubarIconLink = "menubarIcon.link"
case menubarIconNetwork = "menubarIcon.network"
case menubarIconSparkles = "menubarIcon.sparkles"
case menubarIconSwitch = "menubarIcon.switch"
case menubarIconWand = "menubarIcon.wand"
```

- [ ] **Step 6.2: Add translations to `Localizable.xcstrings`**

Open `Sources/AnyDoor/Resources/Localizable.xcstrings`. For every new key in 6.1, add an entry. Template per key:

```json
"builtin.muteAudio" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Mute" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "静音" } }
  }
},
```

Full mapping (en / zh-Hans):

| Key | en | zh-Hans |
|---|---|---|
| `builtin.appShortcuts` | App Shortcuts | 应用快捷键 |
| `builtin.autoHideMenuBar` | Auto-Hide Menu Bar | 自动隐藏菜单栏 |
| `builtin.darkMode` | Dark Mode | 深色模式 |
| `builtin.displaySleep` | Display Sleep | 显示器睡眠 |
| `builtin.emptyTrash` | Empty Trash | 清空废纸篓 |
| `builtin.flushDNS` | Flush DNS | 刷新 DNS |
| `builtin.hideDesktopIcons` | Hide Desktop Icons | 隐藏桌面图标 |
| `builtin.hideDock` | Hide Dock | 隐藏 Dock |
| `builtin.keepAwake` | Keep Awake | Keep Awake |
| `builtin.keyboardLock` | Disable Keyboard | 禁用键盘 |
| `builtin.lockScreen` | Lock Screen | 锁定屏幕 |
| `builtin.muteAudio` | Mute | 静音 |
| `builtin.ocr` | Screen Text Recognition | 屏幕取词 |
| `builtin.pickColor` | Pick Color | 屏幕取色 |
| `builtin.portManager` | Port Manager | 端口管理 |
| `builtin.qrcode` | Recognize QR Code | 识别二维码 |
| `builtin.restartDock` | Restart Dock | 重启 Dock |
| `builtin.restartFinder` | Restart Finder | 重启访达 |
| `builtin.restartMenuBar` | Restart Menu Bar | 重启菜单栏 |
| `builtin.screenshot` | Screenshot to Clipboard | 截图到剪贴板 |
| `builtin.showHiddenFiles` | Show Hidden Files | 显示隐藏文件 |
| `builtin.systemSleep` | System Sleep | 系统休眠 |
| `menubarIcon.appConnected` | App connection | 应用连接 |
| `menubarIcon.bolt` | Bolt | 闪电 |
| `menubarIcon.command` | Command | Command |
| `menubarIcon.connectedPoints` | Connected dots | 连接点 |
| `menubarIcon.cycle` | Cycle | 循环 |
| `menubarIcon.doorLeft` | Left door | 左开门 |
| `menubarIcon.globe` | Globe | 地球 |
| `menubarIcon.grid2x2` | 2×2 grid | 网格 |
| `menubarIcon.grid3x3` | 3×3 grid | 九宫格 |
| `menubarIcon.link` | Link | 链接 |
| `menubarIcon.network` | Network | 网络 |
| `menubarIcon.sparkles` | Sparkles | 闪光 |
| `menubarIcon.switch` | Switch | 切换 |
| `menubarIcon.wand` | Wand | 魔杖 |

- [ ] **Step 6.3: Replace `BuiltinItem.title` with `titleKey: L10n.Key`**

Edit `Sources/AnyDoor/Models/BuiltinItem.swift` lines 45–70:

```swift
var titleKey: L10n.Key {
    switch self {
    case .appShortcuts:      return .builtinAppShortcuts
    case .keepAwake:         return .builtinKeepAwake
    case .muteAudio:         return .builtinMuteAudio
    case .hideDesktopIcons:  return .builtinHideDesktopIcons
    case .showHiddenFiles:   return .builtinShowHiddenFiles
    case .darkMode:          return .builtinDarkMode
    case .lockScreen:        return .builtinLockScreen
    case .emptyTrash:        return .builtinEmptyTrash
    case .screenshot:        return .builtinScreenshot
    case .ocr:               return .builtinOCR
    case .pickColor:         return .builtinPickColor
    case .displaySleep:      return .builtinDisplaySleep
    case .systemSleep:       return .builtinSystemSleep
    case .hideDock:          return .builtinHideDock
    case .autoHideMenuBar:   return .builtinAutoHideMenuBar
    case .restartFinder:     return .builtinRestartFinder
    case .restartDock:       return .builtinRestartDock
    case .restartMenuBar:    return .builtinRestartMenuBar
    case .flushDNS:          return .builtinFlushDNS
    case .keyboardLock:      return .builtinKeyboardLock
    case .portManager:       return .builtinPortManager
    case .qrcode:            return .builtinQRCode
    }
}
```

Delete the old `var title: String { … }` block.

- [ ] **Step 6.4: Replace `MenuBarIcon.Choice.title: String` with `titleKey: L10n.Key`**

Edit `Sources/AnyDoor/Models/MenuBarIcon.swift`:

```swift
struct Choice: Equatable, Sendable {
    let name: String
    let titleKey: L10n.Key
}

static let choices: [Choice] = [
    Choice(name: "door.left.hand.open", titleKey: .menubarIconDoorLeft),
    Choice(name: "sparkles", titleKey: .menubarIconSparkles),
    Choice(name: "wand.and.sparkles", titleKey: .menubarIconWand),
    Choice(name: "bolt.fill", titleKey: .menubarIconBolt),
    Choice(name: "command", titleKey: .menubarIconCommand),
    Choice(name: "switch.2", titleKey: .menubarIconSwitch),
    Choice(name: "square.grid.2x2", titleKey: .menubarIconGrid2x2),
    Choice(name: "circle.grid.3x3.fill", titleKey: .menubarIconGrid3x3),
    Choice(name: "point.3.connected.trianglepath.dotted", titleKey: .menubarIconConnectedPoints),
    Choice(name: "app.connected.to.app.below.fill", titleKey: .menubarIconAppConnected),
    Choice(name: "arrow.trianglehead.2.clockwise", titleKey: .menubarIconCycle),
    Choice(name: "link", titleKey: .menubarIconLink),
    Choice(name: "network", titleKey: .menubarIconNetwork),
    Choice(name: "globe", titleKey: .menubarIconGlobe),
]
```

And update `title(for:)` to return a localized string (renamed to `titleKey(for:)` returning the key, plus a localized-string helper):

```swift
@MainActor
static func localizedTitle(for name: String) -> String {
    if let choice = choices.first(where: { $0.name == name }) {
        return L(choice.titleKey)
    }
    return name
}
```

Delete the old `static func title(for name: String) -> String { … }`.

- [ ] **Step 6.5: Update `PanelEntry` and `PanelStore` to defer localization**

Edit `Sources/AnyDoor/Models/PanelEntry.swift`. Keep `title: String` as-is for app-shortcut entries (those are user-provided app names). For builtin entries the `title` field will hold a placeholder that views never read — instead add:

```swift
@MainActor
func localizedTitle() -> String {
    switch source {
    case .appShortcut: return title
    case .builtin(let item): return L(item.titleKey)
    }
}
```

Edit `Sources/AnyDoor/Services/PanelStore.swift` line 71. Replace `title: item.title,` with `title: "",` (the field is no longer read for builtins). If there is also a `subtitle` derived from `item.title`, leave it empty too — Task 8 will address subtitles when migrating views.

- [ ] **Step 6.6: Update `GeneralSettingsView` icon picker references**

Edit lines 142 and 148 of `Sources/AnyDoor/Views/GeneralSettingsView.swift`:

```swift
.accessibilityLabel(L(choice.titleKey))
// …
.help(MenuBarIcon.localizedTitle(for: selectedMenuBarIconName))
```

- [ ] **Step 6.7: Update every other reference to `entry.title` so they read `entry.localizedTitle()` instead**

Audit and fix call sites (these are the places to touch; later tasks will handle the surrounding strings):

- `Sources/AnyDoor/Views/PanelRowView.swift:34` — `Text(entry.title)` → `Text(entry.localizedTitle())`
- `Sources/AnyDoor/Views/AppShortcutsPopoverView.swift:61` — `Text(entry.title)` → `Text(entry.localizedTitle())`
- `Sources/AnyDoor/Views/AppShortcutsPopoverView.swift:73` — `.help("切换 \(entry.title)")` → keep the Chinese for now (migrated in Task 7); just swap `entry.title` → `entry.localizedTitle()`
- `Sources/AnyDoor/Views/PanelSettingsView.swift:73, 109, 115, 180` — `entry.title` / `child.title` → `entry.localizedTitle()` / `child.localizedTitle()`

Leave `PanelSettingsView.swift:127` (`existingTitle: existing.title`) and `:236` (`panel.title = "选择应用程序"`) for Task 9.

- [ ] **Step 6.8: Build**

Run: `swift build`
Expected: success. If you see `'title' is no longer available`, audit the remaining call sites with `grep -rn 'entry\.title\|\.title\b' Sources/AnyDoor`.

- [ ] **Step 6.9: Add `BuiltinItemLocalizationTests`**

Create `Tests/AnyDoorTests/BuiltinItemLocalizationTests.swift`:

```swift
import XCTest
@testable import AnyDoor

@MainActor
final class BuiltinItemLocalizationTests: XCTestCase {
    func test_everyBuiltinHasATitleKey() {
        for item in BuiltinItem.allCases {
            let key = item.titleKey
            XCTAssertFalse(key.rawValue.isEmpty, "missing titleKey for \(item)")
        }
    }

    func test_titleKeyMapsToNonEmptyTranslation() {
        let manager = LocalizationManager()
        manager.preference = .en
        for item in BuiltinItem.allCases {
            let s = L(item.titleKey)
            XCTAssertFalse(s.isEmpty, "empty translation for \(item)")
            XCTAssertNotEqual(s, item.titleKey.rawValue, "unresolved key for \(item)")
        }
    }
}
```

- [ ] **Step 6.10: Run tests**

Run: `swift test --filter BuiltinItemLocalizationTests`
Expected: pass.

- [ ] **Step 6.11: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift \
        Sources/AnyDoor/Models/MenuBarIcon.swift \
        Sources/AnyDoor/Models/PanelEntry.swift \
        Sources/AnyDoor/Services/PanelStore.swift \
        Sources/AnyDoor/Utilities/L10n.swift \
        Sources/AnyDoor/Resources/Localizable.xcstrings \
        Sources/AnyDoor/Views/GeneralSettingsView.swift \
        Sources/AnyDoor/Views/PanelRowView.swift \
        Sources/AnyDoor/Views/AppShortcutsPopoverView.swift \
        Sources/AnyDoor/Views/PanelSettingsView.swift \
        Tests/AnyDoorTests/BuiltinItemLocalizationTests.swift
git commit -m "feat(i18n): migrate BuiltinItem + MenuBarIcon models to L10n keys"
```

---

## Task 7: Migrate menu bar panel views

**Files (one task per file; commit after each):**
- `Sources/AnyDoor/Views/MenuBarView.swift`
- `Sources/AnyDoor/Views/PanelRowView.swift`
- `Sources/AnyDoor/Views/AppShortcutsPopoverView.swift`
- `Sources/AnyDoor/Views/HotkeyRecorder.swift`

Apply the recipe at the top of this plan. For each file:

- [ ] **Step 7.1: List remaining Chinese literals**

Run: `grep -nE '"[^"]*[一-鿿]+[^"]*"' Sources/AnyDoor/Views/MenuBarView.swift`

For each match, add a `panel.*` or `hotkey.recorder.*` key to `L10n.Key` and to `Localizable.xcstrings` with both translations. Use the table guidelines:

- Empty state copy → `panel.emptyState.title`
- "切换 X" (toggle hover help) → `panel.appShortcut.toggleHelp` with `%@` for the name; render as `L(.panelAppShortcutToggleHelp, entry.localizedTitle())`
- Hotkey recorder placeholders → `hotkey.recorder.placeholder`, `hotkey.recorder.recording`, `hotkey.recorder.conflict`

- [ ] **Step 7.2: Apply substitutions per the recipe**

After editing each file run `swift build`. Fix any `cannot find … in scope` errors by adding the missing `L10n.Key` case.

- [ ] **Step 7.3: Commit per file**

```bash
git add Sources/AnyDoor/Views/<file>.swift Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(i18n): migrate <file> to L10n keys"
```

Repeat 7.1–7.3 for each of the four files. After the last one:

- [ ] **Step 7.4: Final check — no Chinese left in the panel views**

Run: `grep -rEn '"[^"]*[一-鿿]+[^"]*"' Sources/AnyDoor/Views/MenuBarView.swift Sources/AnyDoor/Views/PanelRowView.swift Sources/AnyDoor/Views/AppShortcutsPopoverView.swift Sources/AnyDoor/Views/HotkeyRecorder.swift`
Expected: empty output.

---

## Task 8: Migrate clipboard / port / update / screenshot popover views

**Files (one commit per file):**
- `Sources/AnyDoor/Views/ClipboardHistoryPopoverView.swift`
- `Sources/AnyDoor/Views/ClipboardHistoryRow.swift` (if it has literals — check first)
- `Sources/AnyDoor/Views/PortManagerPopoverView.swift`
- `Sources/AnyDoor/Views/PortListView.swift`
- `Sources/AnyDoor/Views/PortTreeView.swift`
- `Sources/AnyDoor/Views/UpdateBannerView.swift`
- `Sources/AnyDoor/Views/ScreenshotPreviewWindow.swift`
- `Sources/AnyDoor/Views/HoverPopover.swift` (if it has literals)
- `Sources/AnyDoor/Views/ToastView.swift`

Note: `ClipboardHistoryKind.title` (referenced at `ClipboardHistoryPopoverView.swift:65`) lives in `Sources/AnyDoor/Models/ClipboardHistoryItem.swift`. Migrate it the same way `BuiltinItem.title` was — add `titleKey` returning an `L10n.Key`, render in the view as `LocalizedText(kind.titleKey)`. Add `clipboard.kind.ocr`, `clipboard.kind.color`, `clipboard.kind.qrcode`, `clipboard.kind.screenshot` keys.

- [ ] **Step 8.1**: For each file, run the recipe. Use namespaces:
  - `clipboard.*` — clipboard popover UI, row labels, empty state
  - `port.*` — port manager / list / tree UI, table headers, action buttons
  - `update.banner.*` — update banner copy
  - `screenshot.preview.*` — screenshot preview window
  - `toast.*` — generic toast labels

- [ ] **Step 8.2**: Commit each file separately.

- [ ] **Step 8.3**: Verify no Chinese remains:

Run: `grep -rEn '"[^"]*[一-鿿]+[^"]*"' Sources/AnyDoor/Views/`
The output should now only show files migrated in Tasks 9/10.

---

## Task 9: Migrate settings views

**Files (commit per file):**
- `Sources/AnyDoor/Views/SettingsView.swift`
- `Sources/AnyDoor/Views/PanelSettingsView.swift`
- `Sources/AnyDoor/Views/GeneralSettingsView.swift`

- [ ] **Step 9.1**: Apply the recipe. Namespaces:
  - `settings.tab.*` — tab labels in `SettingsView`
  - `settings.general.*` — General tab (including `settings.general.language`, `settings.general.languageOption.system`, `settings.general.languageOption.zh`, `settings.general.languageOption.en` for the Picker added in Task 5)
  - `settings.panel.*` — Panel tab
  - `settings.appPicker.*` — `panel.title = "选择应用程序"` becomes `panel.title = L(.settingsAppPickerTitle)`

- [ ] **Step 9.2**: Commit per file.

- [ ] **Step 9.3**: Verify:

Run: `grep -rEn '"[^"]*[一-鿿]+[^"]*"' Sources/AnyDoor/Views/SettingsView.swift Sources/AnyDoor/Views/PanelSettingsView.swift Sources/AnyDoor/Views/GeneralSettingsView.swift`
Expected: empty.

---

## Task 10: Migrate services and providers

**Files (commit per file):**
- `Sources/AnyDoor/Services/PanelStore.swift`
- `Sources/AnyDoor/Services/ClipboardHistoryStore.swift`
- `Sources/AnyDoor/Services/Providers/OCRProvider.swift`
- `Sources/AnyDoor/Services/Providers/PickColorProvider.swift`
- `Sources/AnyDoor/Services/Providers/QRCodeProvider.swift`
- Any `Models/ClipboardHistoryItem.swift` strings not migrated in Task 8

- [ ] **Step 10.1**: Apply the recipe. Provider strings are usually toast / alert messages — use `toast.*` or `alert.*` namespaces.

- [ ] **Step 10.2**: For provider strings consumed via `Task { @MainActor in … }`, `L(…)` is safe (it's `@MainActor`). If a provider needs the string off the main actor, capture the resolved string into a `let` on the main actor first, then pass the resulting `String` value into the actor task.

- [ ] **Step 10.3**: Commit per file.

- [ ] **Step 10.4**: Verify the entire `Sources/AnyDoor/` is clean:

Run: `grep -rEn '"[^"]*[一-鿿]+[^"]*"' Sources/AnyDoor/`
Expected: empty (no Chinese literals remain in source).

---

## Task 11: Make `PanelStore` rebuild on language change

**Files:**
- Modify: `Sources/AnyDoor/Services/PanelStore.swift`

Built-in titles are read from `BuiltinItem.titleKey` at view render time, so panels update automatically. But subtitles, app-shortcut help text composed in `PanelStore`, and any cached strings need a rebuild. Wire that here.

- [ ] **Step 11.1: Observe `LocalizationManager.preference` in `PanelStore.bootstrap`**

Add an `observation` Task that watches `LocalizationManager.shared.preference` (using `withObservationTracking`) and calls `rebuild()` whenever it fires:

```swift
private func observeLanguageChanges() {
    Task { @MainActor [weak self] in
        while !Task.isCancelled {
            await withCheckedContinuation { cont in
                withObservationTracking {
                    _ = LocalizationManager.shared.preference
                } onChange: {
                    cont.resume()
                }
            }
            self?.rebuild()
            self?.rebuildHotkeySnapshots()
        }
    }
}
```

Call `observeLanguageChanges()` at the end of `bootstrap(...)`.

- [ ] **Step 11.2: Build and smoke-run**

Run: `swift build && swift run AnyDoor &`. Open Settings → General → change 界面语言. Open the menu bar panel — built-in row labels switch language live without quitting.

- [ ] **Step 11.3: Commit**

```bash
git add Sources/AnyDoor/Services/PanelStore.swift
git commit -m "feat(i18n): rebuild PanelStore when language preference changes"
```

---

## Task 12: Add coverage test ensuring every key has translations

**Files:**
- Create: `Tests/AnyDoorTests/LocalizationCoverageTests.swift`

- [ ] **Step 12.1: Locate the catalog at test time**

The catalog is bundled into the test executable through the dependency on `AnyDoor`. Find it via `Bundle.module` of the AnyDoor module, or via the resource bundle URL exposed by Swift PM. The simplest approach: read the file directly from the package source tree using `#filePath` to anchor.

Create `Tests/AnyDoorTests/LocalizationCoverageTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class LocalizationCoverageTests: XCTestCase {
    func test_everyL10nKeyHasZhHansAndEnTranslations() throws {
        let catalog = try loadCatalog()
        let strings = catalog["strings"] as? [String: Any] ?? [:]

        var missing: [String] = []
        for key in L10n.Key.allCases {
            guard let entry = strings[key.rawValue] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else {
                missing.append("\(key.rawValue) (no entry)")
                continue
            }
            for lang in ["en", "zh-Hans"] {
                let value = (((localizations[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String) ?? ""
                if value.isEmpty {
                    missing.append("\(key.rawValue) (\(lang) missing)")
                }
            }
        }

        XCTAssertTrue(missing.isEmpty, "Missing translations:\n" + missing.joined(separator: "\n"))
    }

    private func loadCatalog() throws -> [String: Any] {
        // #filePath resolves to Tests/AnyDoorTests/LocalizationCoverageTests.swift.
        // Walk up two levels to the package root, then into Sources/AnyDoor/Resources.
        let here = URL(fileURLWithPath: #filePath)
        let packageRoot = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let catalogURL = packageRoot
            .appendingPathComponent("Sources/AnyDoor/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LocalizationCoverageTests", code: 1)
        }
        return json
    }
}
```

- [ ] **Step 12.2: Remove the `demo.hello` key**

It served as the scaffold. Open `Sources/AnyDoor/Utilities/L10n.swift` and `Sources/AnyDoor/Resources/Localizable.xcstrings` and delete the `demoHello` case and the `demo.hello` catalog entry. Verify no callers (`grep -rn demoHello Sources/`).

- [ ] **Step 12.3: Run tests**

Run: `swift test`
Expected: all tests pass including `LocalizationCoverageTests`. If `LocalizationManagerTests.test_bundleChangesWhenPreferenceChanges` was previously skipped, un-skip it now — with both `.lproj` folders populated it should pass.

- [ ] **Step 12.4: Commit**

```bash
git add Tests/AnyDoorTests/LocalizationCoverageTests.swift \
        Sources/AnyDoor/Utilities/L10n.swift \
        Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "test(i18n): assert every L10n.Key has en + zh-Hans translations"
```

---

## Task 13: Manual verification

- [ ] **Step 13.1: Full build + run**

```bash
swift build
swift run AnyDoor
```

- [ ] **Step 13.2: System-language verification**

Set macOS preferred language to 简体中文 (System Settings → General → Language & Region). Quit AnyDoor with `pkill -INT AnyDoor` and re-run. Confirm:
- Menu bar panel rows are Chinese.
- Settings General tab is Chinese.
- 界面语言 picker default selection is "跟随系统".

- [ ] **Step 13.3: Override to English**

In Settings → General → 界面语言, pick **English**. Within ~0.5s confirm:
- Settings tab labels switch to English (View / Components labeled accordingly).
- Menu bar panel reopened — rows now read "Mute", "Lock Screen", etc.

- [ ] **Step 13.4: Override back to 中文, then to "跟随系统"**

Verify the panel labels track the change without restart.

- [ ] **Step 13.5: Persistence**

Quit and relaunch. The last-chosen preference is restored.

- [ ] **Step 13.6: Final commit (if any cleanups needed)**

If the verification surfaces stragglers, address each in a small commit with message `fix(i18n): <what>`.

---

## Self-Review Notes

- Spec coverage: §A (architecture) — Tasks 1–4; §B (call-site migration / key convention) — Tasks 6–10; §C (edge cases, tests, out-of-scope) — Tasks 6 (assertions), 11, 12, 13; Settings picker — Task 5.
- The `BuiltinItem.title` → `titleKey` rename and `MenuBarIcon.Choice.title` → `titleKey` rename in Task 6 line up with spec §B's "Model-layer rule".
- `PanelStore` rebuild on language change (Task 11) is the spec's "Risks: views that don't observe the manager won't re-render" mitigation for value types stored in `PanelEntry`.
- `LocalizationCoverageTests` (Task 12) satisfies the spec's testing requirement for "every key has both translations".
- No placeholder steps: every code block above is executable.
- Type/name consistency: `LanguagePreference`, `LocalizationManager`, `L10n.Key`, `L(_:_:)`, `LocalizedText` are defined in Tasks 2–3 and referenced uniformly thereafter; `titleKey` is the name in both `BuiltinItem` and `MenuBarIcon.Choice`.
