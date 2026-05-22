# AnyDoor

macOS 菜单栏应用，通过全局快捷键一键切换（打开/隐藏）指定应用程序。

## 技术栈

- Swift 6.2，严格并发模式 (`.swiftLanguageMode(.v6)`)
- macOS 26+ (Tahoe)
- SwiftUI (`MenuBarExtra` + `Settings`)
- SwiftData 持久化
- CGEvent tap 全局热键监听
- SPM 构建

## 构建和运行

```bash
# 构建
swift build

# 运行（开发模式，进程身份不带 Bundle ID）
swift run AnyDoor

# Release 构建
swift build -c release

# 安装为 /Applications/AnyDoor.app（写入 Info.plist，Bundle ID = dev.bybee.AnyDoor）
make install

# 卸载
make uninstall

# 热重载开发（需要 watchexec）
make
```

运行需要 macOS 辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能）。

`swift run` 和 `make install` 后的 `.app` 是**两个不同的进程身份**，需要分别授权辅助功能。生产使用走 `make install`；日常开发用 `swift run`。SwiftData 存储路径已被固定，两种方式共享同一份数据（见下文）。

## 项目结构

```
Sources/AnyDoor/
├── AnyDoor.swift              # @main, MenuBarExtra + Settings Scene
├── AppDelegate.swift           # ModelContainer, providers registry, HotkeyService bootstrap
├── Models/
│   ├── KeyBinding.swift        # App shortcut bindings (SwiftData)
│   ├── BuiltinItem.swift       # Code-defined catalog of system toggle/action items
│   ├── BuiltinPreference.swift # User customization (visibility / order / hotkey) for built-ins
│   ├── PanelEntry.swift        # Unified view model + HotkeyDescriptor + PermissionStatus
│   └── HotkeyAction.swift      # HotkeyAction enum + HotkeySnapshot
├── Services/
│   ├── HotkeyService.swift     # CGEvent tap, dispatches HotkeyAction via injected closure
│   ├── PanelStore.swift        # @Observable, merges all three sources, owns provider registry
│   ├── AppSwitcher.swift       # App launch/hide/activate
│   ├── AppleScriptRunner.swift # NSAppleScript wrapper
│   ├── ShellRunner.swift       # Process + timeout wrapper
│   ├── BuiltinPreferenceSeeder.swift
│   ├── KeyBindingOrderBackfill.swift
│   └── Providers/
│       ├── BuiltinProvider.swift
│       ├── KeepAwakeProvider.swift
│       ├── HideDesktopIconsProvider.swift
│       ├── ShowHiddenFilesProvider.swift
│       ├── MuteAudioProvider.swift
│       ├── DarkModeProvider.swift
│       ├── LockScreenProvider.swift
│       └── EmptyTrashProvider.swift
├── Utilities/
│   └── KeyCodeMap.swift
└── Views/
    ├── MenuBarView.swift              # Menu bar panel root
    ├── PanelRowView.swift             # Single row: toggle / action / submenu
    ├── HoverPopover.swift             # NSWindow side popover + HoverGate timing
    ├── AppShortcutsPopoverView.swift  # Popover content for app shortcuts
    ├── HotkeyRecorder.swift           # Inline hotkey recording field
    ├── SettingsView.swift             # TabView host
    ├── PanelSettingsView.swift        # 面板 tab: drag / visibility / hotkey
    └── GeneralSettingsView.swift      # 通用 tab (placeholder)
```

## 架构要点

- **ModelContainer 共享**：在 `AppDelegate.init()` 中创建，通过 `.modelContainer()` 传递给所有 SwiftUI 视图。不要创建多个 ModelContainer 实例。
- **固定存储路径**：ModelContainer 显式配置 `url: ~/Library/Application Support/dev.bybee.AnyDoor/AnyDoor.store`，避免 `swift run` 和 `.app` 因 Bundle ID 差异写入不同位置。`AppDelegate` 启动时会一次性从遗留 `default.store` 迁移并清理（见 `migrateLegacyStore`）。**修改 ModelConfiguration 时必须保留这条路径**，否则用户数据会"丢失"。
- **CGEvent 回调并发安全**：回调函数是 C 风格的自由函数，不在 `@MainActor` 上。使用 `HotkeySnapshot`（Sendable 值类型，含 `HotkeyAction`）+ `nonisolated(unsafe)` 存储来安全传递数据。
- **CGEvent tap 超时与 watchdog**：系统对 tap 回调有 ~1 秒预算，超时会触发 `.tapDisabledByTimeout` 自动禁用 tap。当前防御方式：
  - 回调只做按键匹配，实际工作 `DispatchQueue.main.async` 派发
  - 收到 `tapDisabledBy*` 时回调内 inline 重新启用
  - 2 秒 watchdog 检测 `CGEvent.tapIsEnabled`，必要时 `restart()`（销毁并重建 tap）
  - **绝不要在回调里做同步耗时工作**（I/O、SwiftData fetch、模态弹窗等）
- **修饰键对齐**：录入和检测都使用 `CGEventFlags` 位掩码（`maskCommand | maskControl | maskAlternate | maskShift`），不要用 `NSEvent.ModifierFlags`。
- **录入时暂停监听**：录入快捷键时调用 `HotkeyService.suspend()`，完成后 `resume()`，避免录入触发已有绑定。watchdog 通过 `isSuspended` 跳过自动重启。
- **数据变更通知**：增删绑定后显式调用 `modelContext.save()` 和 `AppDelegate.refreshBindings()` 刷新 HotkeyService。
- **切换语义**：`AppSwitcher.toggle` 用 `app.isActive`（最前应用判定）而非 `app.isHidden`。当目标已是最前则 `hide()`，否则 `activate()`；未运行则 `openApplication`。改判定条件会改变交互语义。
- **PanelStore 是单一真相源**：三路数据（BuiltinItem 静态清单 + BuiltinPreference 偏好 + KeyBinding 应用快捷键）在 `PanelStore` 合并；视图只读 `topLevelEntries` 与 `appShortcutChildren`。**写入路径都要经过 PanelStore 的 mutation 方法**（setBuiltinVisibility、setBuiltinHotkey、reorderTopLevel 等），它们会自动 save SwiftData、rebuild 视图状态、并 `rebuildHotkeySnapshots()` 推到 HotkeyService。
- **HotkeyAction 派发**：HotkeyService 的回调使用注入的 `dispatcher` 闭包，在 `AppDelegate.applicationDidFinishLaunching` 中绑定到 `PanelStore.shared.dispatch`；不要直接在 HotkeyService 内引用 PanelStore，保持 HotkeyService 与具体业务解耦。
- **Provider 隔离**：每个 ToggleProvider / ActionProvider 是独立 actor，setState 在自己的 actor 上串行；`PanelStore` 是 `@MainActor`，跨 Provider 的写操作通过 `Task { await … }` 在 MainActor 调度。

## 相关 Skills

以下 skills 已安装，在相关任务中应主动使用：

- **macos-design-guidelines** — Apple HIG for Mac。构建 macOS UI、菜单栏、工具栏、窗口管理、键盘快捷键时使用。
- **axiom-swiftdata** — SwiftData 模式，@Model、@Query、@Relationship、ModelContext 模式、Swift 6 并发时使用。
- **axiom-swiftui-26-ref** — iOS/macOS 26 SwiftUI 新特性，Liquid Glass 设计系统、@Animatable 宏等。
- **swiftui-liquid-glass** — Liquid Glass API 实现和审查。
- **axiom-swift-concurrency** — Swift 并发模式，@MainActor、Sendable、nonisolated(unsafe)、Task、Actor 等并发安全模式。
- **swift-expert** — Swift 语言专家知识，覆盖语言特性和最佳实践。
- **macos-developer** — macOS 应用开发，CGEvent、NSWorkspace、辅助功能权限等底层 API。

## 注意事项

- 应用使用 `.accessory` 激活策略，不显示 Dock 图标
- 事件 tap 使用 `.cghidEventTap` 确保最高优先级
- `displayKey` 是 `@Transient` 计算属性，不持久化
- 界面语言为中文

## Code Conventions

- **All code comments must be written in English.**
- **All commit messages must be written in English.**
- **All PR titles and descriptions must be written in English.**
- UI-facing strings (labels, messages shown to the user) remain in Chinese.
