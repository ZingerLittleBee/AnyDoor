# 菜单栏面板重构 — 设计文档

**日期**：2026-05-20
**状态**：已通过 brainstorm，等待 writing-plans 编排实施
**作者**：AnyDoor / 协作设计

## 1. 目标与范围

将 AnyDoor 从「全局快捷键 → 应用切换」工具扩展为「菜单栏多功能开关面板」。应用快捷键继续是核心能力，但归入面板中的一个分组。

### 1.1 MVP 条目集

| # | 标题 | 类型 | 默认快捷键 | 实现 API |
|---|---|---|---|---|
| 1 | Keep Awake | Toggle | — | IOPMAssertion |
| 2 | 应用快捷键 | Submenu | — | 现有 KeyBinding |
| 3 | 静音 | Toggle | — | CoreAudio |
| 4 | 隐藏桌面图标 | Toggle | — | defaults + killall Finder |
| 5 | 显示隐藏文件 | Toggle | — | defaults + killall Finder |
| 6 | 深色模式 | Toggle | — | AppleScript (System Events) |
| 7 | 锁定屏幕 | Action | — | 私有 API 或 CGSession shell |
| 8 | 清空废纸篓 | Action | — | AppleScript (Finder) |

默认快捷键留空，由用户在设置中按需绑定。

### 1.2 不在 MVP 范围

- Focus / 勿扰切换、Night Shift、True Tone、Bluetooth / WiFi 等需要更复杂 API 的开关
- AirPods 电量等状态展示型条目
- 自定义图标主题、Liquid Glass 强度调节
- 开机自启动（在「通用」Tab 占位）
- iCloud 同步用户偏好

## 2. 架构总览

```
                ┌─────────────────────────────────────────┐
                │           SwiftUI 视图层                 │
                │  MenuBarView   ·   SettingsView         │
                └────────────────┬────────────────────────┘
                                 │
              ┌──────────────────▼─────────────────┐
              │            PanelStore               │   合并三路 → 排序后的 [PanelEntry]
              │      (@Observable, MainActor)      │
              └──────┬──────────┬───────────┬──────┘
                     │          │           │
        ┌────────────▼──┐  ┌────▼─────┐  ┌─▼──────────────┐
        │ BuiltinCatalog│  │Preference│  │  KeyBinding    │
        │ (代码内静态)   │  │(SwiftData│  │  (SwiftData)   │
        │               │  │  偏好)   │  │  应用快捷键    │
        └──────┬────────┘  └──────────┘  └────────────────┘
               │
       ┌───────▼────────┐
       │ ToggleProvider │   每个内置条目对应一个 Provider
       │ / ActionProvider │ (read 状态 / write 切换)
       └────────────────┘

              ┌──────────────────────────────────────────┐
              │              HotkeyService                │   现有
              │  CGEvent tap → HotkeyAction 派发          │   ↓ 演进
              │  AppLaunch / ToggleBuiltin / RunBuiltin   │
              └──────────────────────────────────────────┘
```

**核心思想**：内置功能定义在代码里（不可"创建"），用户偏好（顺序/显隐/快捷键）在数据库里，应用快捷键继续是数据库表；三路在 PanelStore 合并。

## 3. 数据模型

### 3.1 SwiftData 模型

```swift
// 演进：增 isVisible / displayOrder；isEnabled 含义微调
@Model
final class KeyBinding {
    @Attribute(.unique) var id: UUID
    var keyCode: Int
    var modifierFlags: Int
    var appBundleID: String
    var appName: String
    var appPath: String
    var isEnabled: Bool        // 快捷键是否激活（false = 即使在子菜单也不响应快捷键）
    var isVisible: Bool        // 新增：是否在「应用快捷键」子菜单中显示
    var displayOrder: Double   // 新增：在子菜单中的排序权重（浮点便于插入）
    var createdAt: Date
}

// 两个字段独立：
// - isEnabled 影响「快捷键是否会触发应用切换」
// - isVisible 影响「是否在子菜单和设置列表中可见」
// 常见组合：临时禁用快捷键但保留绑定（isEnabled=false, isVisible=true）；
// 或藏起一个不常用绑定（isEnabled=true, isVisible=false，hotkey 仍能触发）。

// 新增
@Model
final class BuiltinPreference {
    @Attribute(.unique) var itemKey: String   // BuiltinItem.rawValue
    var isVisible: Bool
    var displayOrder: Double
    var keyCode: Int?            // nil = 未绑快捷键
    var modifierFlags: Int?
}
```

### 3.2 内置清单（代码内）

```swift
enum BuiltinItem: String, CaseIterable {
    case appShortcuts            // 子菜单父节点（特殊：自身不切换，仅承载子项）
    case keepAwake, muteAudio,
         hideDesktopIcons, showHiddenFiles,
         darkMode,
         lockScreen, emptyTrash

    var kind: Kind { ... }                // .toggle / .action / .submenu
    var title: String { ... }
    var symbol: String { ... }            // SF Symbol
    var defaultOrder: Double { ... }
    var requiresAutomation: Bool { ... }

    enum Kind { case toggle, action, submenu }
}
```

注意：`appShortcuts` 是特殊的 submenu 类型，不实现 ToggleProvider/ActionProvider，仅作为 UI 锚点；子项数据来源是 KeyBinding 表。

### 3.3 运行时统一类型

```swift
struct PanelEntry: Identifiable, Hashable {
    enum Source {
        case appShortcut(KeyBinding.ID)
        case builtin(BuiltinItem)
    }
    let id: String                  // "app:<uuid>" 或 "builtin:<key>"
    let source: Source
    let displayOrder: Double
    let isVisible: Bool
    let hotkey: HotkeyDescriptor?
    let title: String
    let subtitle: String?
    let symbol: String
    let kind: BuiltinItem.Kind
    let toggleState: Bool?          // 仅 .toggle，由 PanelStore 注入
    let permission: PermissionStatus
}

struct HotkeyDescriptor: Hashable, Sendable {
    let keyCode: Int
    let modifierFlags: Int
    var displayString: String { ... }
}
```

PanelStore 对外暴露两个独立集合（避免视图层混淆）：

- `topLevelEntries: [PanelEntry]` — 全部 BuiltinItem 派生的条目（含 appShortcuts 这个 submenu 节点），按 BuiltinPreference.displayOrder 排序。MenuBarView 的主面板和 SettingsView 的统一列表都迭代这个。
- `appShortcutChildren: [PanelEntry]` — 全部 KeyBinding 派生的条目（每个 app 一条），按 KeyBinding.displayOrder 排序。MenuBarView 的 hover 侧弹、SettingsView 中 appShortcuts 行下的缩进列表都迭代这个。

两个集合的排序在不同维度上：top-level 的 displayOrder 决定面板/设置主列表的顺序；children 的 displayOrder 决定子菜单/缩进列表的顺序。互不混合。

### 3.4 数据迁移

启动迁移在 `AppDelegate.init()` 中执行：

1. **现有 KeyBinding 行**：SwiftData 自动迁移会为新字段写入声明的默认值。代码中将 `isVisible` 和 `displayOrder` 声明为 `Bool = true` / `Double = 0` 即可让旧数据可读
2. **displayOrder 回填**：迁移后扫描所有 `displayOrder == 0` 的旧条目，按 `createdAt` 升序赋递增值（与新建条目避免冲突）
3. **BuiltinPreference 首次播种**：表为空时按 `BuiltinItem.allCases` 播种，每项使用 `defaultOrder`、`isVisible = true`、`keyCode = nil`
4. **后续启动 diff**：对比 `BuiltinItem.allCases` 与已有 `itemKey`，补齐缺失项（displayOrder 取当前最大值 + 1）；遗留 itemKey 通过 `BuiltinItem(rawValue:)` 自然跳过，无需主动清理

复用现有 legacy store 迁移的事务模式，所有迁移在一个 ModelContext 内完成 + save。

## 4. Builtin Provider 抽象

### 4.1 协议

```swift
protocol BuiltinProvider {
    var itemKey: BuiltinItem { get }
    var permission: PermissionStatus { get async }
}

protocol ToggleProvider: BuiltinProvider {
    func readState() async throws -> Bool
    func setState(_ enabled: Bool) async throws
}

protocol ActionProvider: BuiltinProvider {
    func run() async throws
}

enum PermissionStatus { case granted, denied, undetermined, notRequired }

enum BuiltinError: Error {
    case missingAutomationPermission
    case appleScriptFailed(code: Int, message: String)
    case shellFailed(code: Int32, output: String)
    case audioDeviceUnavailable
    case ioKitFailed(IOReturn)
}
```

每个 Provider 是独立 actor，setState/readState 在自身 actor 上执行（避免同条目并发翻转）。`PanelStore` 是 `@MainActor`。

### 4.2 各 Provider 实现路径

| Provider | 实现 |
|---|---|
| **KeepAwakeProvider** | `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep, ...)` 持有 ID；setState(false) 调 `IOPMAssertionRelease`；进程退出自动清理 |
| **HideDesktopIconsProvider** | 读：`CFPreferencesCopyAppValue("CreateDesktop", "com.apple.finder")`；写：`Process` 调 `/usr/bin/defaults write com.apple.finder CreateDesktop -bool <v>` + `/usr/bin/killall Finder` |
| **ShowHiddenFilesProvider** | 同上，key 为 `AppleShowAllFiles` |
| **MuteAudioProvider** | CoreAudio：取默认输出设备 → `kAudioDevicePropertyMute`；注册 `AudioObjectAddPropertyListener` 监听媒体键导致的状态变更；监听 `kAudioHardwarePropertyDefaultOutputDevice` 处理设备切换 |
| **DarkModeProvider** | AppleScript：`tell System Events to tell appearance preferences to set/return dark mode` |
| **LockScreenProvider** | 优先 `Process` 调 `/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession -suspend`（公开路径，稳定）。私有 API `SACLockScreenImmediate()` 视为可选优化，**默认不使用**——属私有 API，存在 App Store 审核风险与未来版本不可用风险，仅在性能或体验上有可观测优势时再启用 |
| **EmptyTrashProvider** | AppleScript：`tell application "Finder" to empty the trash` |

### 4.3 共享基础设施

- `AppleScriptRunner.run(_:) async throws -> String`：内部 `Task.detached` + `NSAppleScript`，捕获 `errorInfo` 中的 `NSAppleScriptErrorNumber` 映射为 `BuiltinError`
- `ShellRunner.run(_ path:, args:) async throws -> String`：`Process` + `Pipe`，超时（5s）+ exit code 检查
- `PermissionProbe`：首次调用 AppleScript 失败 -1743 时缓存 `.denied`；用户授权后通过下一次成功调用刷新

## 5. HotkeyAction 路由

### 5.1 类型演进

```swift
struct HotkeySnapshot: Sendable {
    let keyCode: Int
    let modifierFlags: Int
    let action: HotkeyAction
}

enum HotkeyAction: Sendable {
    case launchApp(bundleID: String, path: String)
    case toggleBuiltin(itemKey: String)
    case runBuiltin(itemKey: String)
}
```

`HotkeyService.bindingSnapshots` 改名为 `hotkeySnapshots`；`nonisolated(unsafe)` 存储、CGEvent tap 回调逻辑、watchdog、suspend/resume 全部保持不变。

### 5.2 回调派发

回调匹配后：

```swift
DispatchQueue.main.async {
    PanelStore.shared.dispatch(action)
}
return nil   // 消费事件
```

`PanelStore.dispatch(_:)` 在 `@MainActor` 上 switch action：
- `.launchApp` → `AppSwitcher.toggle`（现有，不变）
- `.toggleBuiltin(key)` → `provider.readState() → setState(!current)`
- `.runBuiltin(key)` → `provider.run()`

### 5.3 快照构建

PanelStore 在以下时机重建 hotkeySnapshots：
- 启动完成（替代现有 `refreshBindings`）
- KeyBinding 增删改
- BuiltinPreference 改（顺序/显隐/绑键）

构建逻辑：
- KeyBinding 表中 `isEnabled == true` 的条目 → `.launchApp`（注意：isVisible 不参与，因为快捷键即使不在子菜单显示也能触发）
- BuiltinPreference 中 `keyCode != nil` 的条目 → 按 BuiltinItem.kind 派生 `.toggleBuiltin` 或 `.runBuiltin`（内置项无单独 isEnabled，"未绑快捷键" 即等价于"快捷键关闭"）
- `appShortcuts` 父节点不参与快捷键派发（自身无 hotkey）

### 5.4 冲突处理

- **运行时**：按 `hotkeySnapshots` 顺序匹配（即 displayOrder 顺序），命中即消费
- **录入时**：保存前查询当前 snapshots，冲突时弹 sheet「已被 XX 占用，替换吗？」→ 替换则清空冲突方的 hotkey，再保存新值

## 6. 菜单栏面板 UI

### 6.1 行类型

| 类型 | 视觉规范 |
|---|---|
| **Toggle** | 24×24 圆角图标 + 标题 + 可选副标题（hotkey 或状态描述） + 右侧 Toggle switch。整行可点击翻转。 |
| **Action** | 24×24 圆角图标 + 标题 + 右侧灰色快捷键提示（无 switch）。整行可点击触发。 |
| **Submenu trigger**（仅 appShortcuts） | 24×24 圆角图标 + 标题 + 副标题（"N 个绑定"） + 右侧 chevron ›。Hover 400ms 弹侧窗，点击同样弹出。 |
| **权限缺失态** | 图标橙色背景、副标题橙色 "⚠ 需要权限"，点击行打开 `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`；Toggle 视觉禁用。 |

行的启用/禁用状态（toggleState）由 PanelStore 注入；图标可见时取启用色背景，灰时取中性背景。

### 6.2 整体布局

- 宽度 260pt，最小高 400pt（与现有一致）
- Header：左侧"AnyDoor"、右侧"X 个已启用"（统计 isVisible 的总数）
- 中部：按 displayOrder 列出所有 `isVisible == true` 的 PanelEntry
- Footer：⚙ 设置 / ⏻ 退出（保留现有按钮，glass 样式）

### 6.3 Hover 侧弹

- **触发**：鼠标进入 `appShortcuts` 行 400ms 后弹出；点击立即弹出
- **位置**：贴主面板右侧 4pt；右侧空间不足时翻转贴左侧；垂直与触发行对齐
- **消失**：鼠标同时离开主面板 + 侧弹两区域 300ms 后关闭；主面板关闭时强制关闭
- **键盘**：方向键 →/← 在主面板与侧弹之间切换焦点
- **内容**：`hotkey ▸ appName` 行列表 + 每行右侧小绿点（应用是否在运行），底部"+ 添加应用快捷键"
- **实现**：`NSWindow(.borderless + .nonactivating)` + SwiftUI 内容；坐标由 `NSStatusItem` 主窗 frame 计算得出

### 6.4 状态刷新

- `MenuBarView.onAppear` 调 `panel.refreshAll()`（全量重读所有 ToggleProvider 状态）
- `muteAudio` 例外：CoreAudio listener 持续推送，无需等待面板打开

## 7. 设置窗口

`SettingsView` 保留 TabView，结构：

- **「面板」Tab**：单一统一列表，所有条目（系统 + 应用快捷键）按 displayOrder 渲染
- **「通用」Tab**：占位，预留开机启动等

### 7.1 「面板」Tab 行结构

每行包含：

| 列 | 内容 |
|---|---|
| 拖拽手柄 | `⋮⋮` 图标，SwiftUI `List.onMove` 重排 |
| 显隐复选框 | `isVisible`；未勾选行透明度降低但仍显示 |
| 图标 + 标题 + 类型徽章 | 类型徽章："系统" / "系统 · 动作" / "系统 · 子菜单" |
| 快捷键字段 | 未绑：斜体"点击录入"；已绑：等宽字体徽章。点击进入录入态 |
| 删除按钮 | 系统条目灰显（不可删）；应用快捷键可点 × 删除 |

### 7.2 应用快捷键子列表

在「应用快捷键」父行下方缩进展示个体应用（左侧 2pt 蓝色竖线锚定）：
- 每行同样有：拖拽手柄、显隐勾选、图标 + 应用名、快捷键字段、× 删除
- 子列表末尾："+ 添加应用" 按钮 → 触发 `NSOpenPanel.allowedContentTypes = [.application]`
- 子列表内的 displayOrder 独立于其他面板项排序（仅决定侧弹中的顺序，不混入主面板排序）

### 7.3 HotkeyRecorder 组件

替代现有的 `BindingEditView` 录入流程：

- 未绑定状态显示"点击录入"
- 点击进入录入态：背景高亮，调 `HotkeyService.shared.suspend()`，注册 `NSEvent.addLocalMonitorForEvents(.keyDown)`
- 用户按下组合键 → 记录 (keyCode, modifierFlags)，调用 `onComplete`，`HotkeyService.resume()`
- ESC 取消录入（不修改原值）
- ⌫（无修饰键）清除已绑

### 7.4 冲突 sheet

录入完成提交前，PanelStore 查询冲突：

- 无冲突：直接保存
- 有冲突：弹 sheet 显示"⌃⌥⌘K 已被 Keep Awake 占用"+「替换」/「取消」
- 「替换」：清空原占用方的 hotkey，保存新值

## 8. 权限与错误处理

### 8.1 权限矩阵

| 权限 | 用途 | 检测 | 缺失时 |
|---|---|---|---|
| 辅助功能 | CGEvent tap | `AXIsProcessTrusted()` | 启动时 `AXIsProcessTrustedWithOptions(prompt: true)` |
| 自动化（System Events） | darkMode | dry-run AppleScript，错误 -1743 → denied | 行内 ⚠"需要权限"，点击行打开自动化设置 URL |
| 自动化（Finder） | emptyTrash | 同上，针对 Finder | 同上 |

### 8.2 错误恢复

- **AppleScript 失败**：errorNumber 分类（-1743 权限 / -1728 对象不存在 / 其他通用），抛 `BuiltinError.appleScriptFailed`；UI 在该行副标题位置显示红色错误，3 秒后恢复
- **`killall Finder` 失败**：不阻断流程；defaults 已落盘，下次 Finder 启动生效
- **IOPMAssertion 失败**：toggle 弹回原状态 + 副标题红色"创建唤醒锁失败"
- **CoreAudio 设备拔出**：监听 `kAudioHardwarePropertyDefaultOutputDevice`，重新订阅新设备
- **Provider 未注册**：日志警告 + 静默返回；不应发生

### 8.3 并发

- 同一 Provider 的 setState 串行（actor 隔离）
- 跨 Provider 的快速翻转：因为派发在 `@MainActor`，天然串行
- 系统状态被外部修改：MVP 取「面板 onAppear 全量刷新」；mute 例外用 listener

### 8.4 边界场景

- **首次启动 BuiltinPreference 为空** → 同一事务内播种 + save
- **BuiltinItem 新增**（升级版本带新条目） → 启动 diff，补齐尾部
- **BuiltinItem 移除**（极少） → 孤儿 itemKey 用 `init(rawValue:)` 跳过；可清理
- **应用快捷键指向的 .app 不存在** → toggle 时 `NSWorkspace.openApplication` 失败，行内副标题红色"应用未找到"，引导用户重新选择或删除

## 9. 测试范围

| 类型 | 覆盖 | 工具 |
|---|---|---|
| 单元 | KeyCodeMap、修饰键掩码、displayOrder 排序合并 | XCTest |
| 单元 | HotkeyAction 派发表（mock Provider） | XCTest |
| 单元 | 冲突检测、首次播种、缺失项补齐 | XCTest + in-memory ModelContainer |
| 手测 | hover 侧弹时序、位置翻转、消失延时 | 实机 |
| 手测 | 各 Provider 真实效果 + 权限缺失流程 | 实机 |
| 手测 | watchdog 兼容（连续 toggle 不触发 1s 预算） | 实机 + 日志 |

Provider 内部（AppleScript / IOPMAssertion / killall）不强求单测覆盖。

## 10. 实施工作包

按可独立验证的粒度切：

- **WP-1 数据模型与持久化**：KeyBinding 字段扩展 + BuiltinPreference 新增 + 启动迁移
- **WP-2 Builtin 抽象 + KeepAwakeProvider**：协议层 + PanelStore 骨架 + 一个最简 Provider 走通端到端
- **WP-3 HotkeyAction 路由升级**：BindingSnapshot → HotkeySnapshot 演进，回归现有应用快捷键
- **WP-4 其他 6 个 Provider**：Hide/Show Finder defaults / Mute / DarkMode / LockScreen / EmptyTrash + AppleScriptRunner、ShellRunner 共享设施
- **WP-5 菜单栏面板 UI 重构**：MenuBarView 三种行渲染 + 权限态视觉
- **WP-6 Hover 侧弹**：HoverPopoverWindow + 时序门 + 位置计算 + 键盘
- **WP-7 设置窗口重构**：PanelSettingsView + HotkeyRecorder + 拖拽 + 冲突 sheet
- **WP-8 收尾打磨**：清理废弃 View、CLAUDE.md / README 同步、Info.plist 检查

中间停止点：WP-1+2+3 完成后即有可用的新架构 + 一个端到端 toggle，可以小 release。WP-7 可与 WP-5 并行。

## 11. 与现有架构对齐

CLAUDE.md 中已定下的铁律延续：

- ✅ CGEvent 回调仅做匹配，所有 Provider 调用都通过 `DispatchQueue.main.async` 派发
- ✅ Sendable 快照（`HotkeySnapshot` + `HotkeyAction` 全值类型）
- ✅ 修饰键继续用 CGEventFlags 掩码（录入与匹配对齐）
- ✅ 录入时 suspend/resume HotkeyService
- ✅ Watchdog 与 inline 重启逻辑保持不变
- ✅ 固定 ModelContainer 存储路径保留（`~/Library/Application Support/dev.bybee.AnyDoor/AnyDoor.store`）
- ✅ `AppSwitcher.toggle` 基于 `app.isActive` 判定的行为不变
