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

# 运行
swift run AnyDoor

# Release 构建
swift build -c release
```

运行需要 macOS 辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能）。

## 项目结构

```
Sources/AnyDoor/
├── AnyDoor.swift              # @main 入口，MenuBarExtra + Settings Scene
├── AppDelegate.swift           # 生命周期管理，ModelContainer 创建，HotkeyService 启动
├── Models/
│   └── KeyBinding.swift        # SwiftData @Model，存储快捷键绑定
├── Services/
│   ├── HotkeyService.swift     # CGEvent tap 全局热键监听（.cghidEventTap 最高优先级）
│   └── AppSwitcher.swift       # 应用切换逻辑（打开/隐藏/激活）
├── Utilities/
│   └── KeyCodeMap.swift        # 虚拟键码 ↔ 可读名称映射
└── Views/
    ├── MenuBarView.swift       # 菜单栏弹出窗口 UI
    ├── SettingsView.swift      # 设置窗口 TabView
    ├── BindingListView.swift   # 快捷键列表（增删改）
    ├── BindingEditView.swift   # 快捷键录入 + 应用选择
    └── GeneralSettingsView.swift # 通用设置
```

## 架构要点

- **ModelContainer 共享**：在 `AppDelegate.init()` 中创建，通过 `.modelContainer()` 传递给所有 SwiftUI 视图。不要创建多个 ModelContainer 实例。
- **CGEvent 回调并发安全**：回调函数是 C 风格的自由函数，不在 `@MainActor` 上。使用 `BindingSnapshot`（Sendable 值类型）+ `nonisolated(unsafe)` 存储来安全传递数据。
- **修饰键对齐**：录入和检测都使用 `CGEventFlags` 位掩码（`maskCommand | maskControl | maskAlternate | maskShift`），不要用 `NSEvent.ModifierFlags`。
- **录入时暂停监听**：录入快捷键时调用 `HotkeyService.suspend()`，完成后 `resume()`，避免录入触发已有绑定。
- **数据变更通知**：增删绑定后显式调用 `modelContext.save()` 和 `AppDelegate.refreshBindings()` 刷新 HotkeyService。

## 相关 Skills

以下 skills 已安装，在相关任务中应主动使用：

- **macos-design-guidelines** — Apple HIG for Mac。构建 macOS UI、菜单栏、工具栏、窗口管理、键盘快捷键时使用。
- **axiom-swiftdata** — SwiftData 模式，@Model、@Query、@Relationship、ModelContext 模式、Swift 6 并发时使用。
- **axiom-swiftui-26-ref** — iOS/macOS 26 SwiftUI 新特性，Liquid Glass 设计系统、@Animatable 宏等。
- **swiftui-liquid-glass** — Liquid Glass API 实现和审查。

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
