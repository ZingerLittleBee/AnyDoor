# AnyDoor 实现计划

## 项目概述

AnyDoor 是一个 macOS 菜单栏应用，允许用户通过全局快捷键快速切换（打开/隐藏）应用程序。

## 技术栈

| 项目 | 选择 |
|------|------|
| UI 框架 | SwiftUI + Liquid Glass (macOS 26+) |
| 数据持久化 | SwiftData |
| 全局快捷键 | CGEvent tap |
| 构建方式 | Swift Package Manager |
| 最低系统版本 | macOS 26 (Tahoe) |
| Swift 版本 | 6.2 |

## 文件结构

```
Sources/AnyDoor/
├── AnyDoor.swift                 # @main App 入口
├── AppDelegate.swift             # NSApplicationDelegate，配置菜单栏、CGEvent tap
├── Models/
│   └── KeyBinding.swift          # SwiftData @Model，快捷键-应用映射
├── Views/
│   ├── MenuBarView.swift         # 菜单栏弹出视图（快捷键列表 + 操作按钮）
│   ├── SettingsView.swift        # 设置窗口主视图
│   ├── BindingListView.swift     # 设置 - 快捷键绑定列表
│   ├── BindingEditView.swift     # 设置 - 添加/编辑单个绑定
│   └── GeneralSettingsView.swift # 设置 - 通用设置（预留）
├── Services/
│   ├── HotkeyService.swift       # CGEvent tap 全局快捷键监听
│   └── AppSwitcher.swift         # 应用启动/隐藏/切换逻辑
└── Utilities/
    └── KeyCodeMap.swift          # macOS 虚拟键码 <-> 可读名称映射
```

---

## 实现步骤

### Step 1: 项目基础设施

**目标**: 把 SPM 命令行项目改造为 macOS GUI 应用

**修改文件**:
- `Package.swift` — 添加 macOS 26 平台要求和 SwiftData 依赖
- `Sources/AnyDoor/AnyDoor.swift` — 改为 SwiftUI App 入口

**具体任务**:
1. 修改 `Package.swift`:
   - 添加 `platforms: [.macOS(.v26)]`（或使用对应的 API 版本号）
   - 保持 `executableTarget`
2. 重写 `AnyDoor.swift`:
   - 使用 `@main struct AnyDoorApp: App`
   - 配置 `MenuBarExtra` 作为菜单栏入口
   - 配置 `.modelContainer(for: [KeyBinding.self])`
   - 使用 `Settings` scene 提供设置窗口
   - 设置 `NSApplication.shared.setActivationPolicy(.accessory)` 隐藏 Dock 图标
3. 创建 `AppDelegate.swift`:
   - 实现 `NSApplicationDelegate`
   - 在 `applicationDidFinishLaunching` 中初始化 HotkeyService
   - 处理辅助功能权限请求

**验证**: `swift build` 成功，运行后在菜单栏显示图标

---

### Step 2: SwiftData Model

**目标**: 定义快捷键绑定的数据模型

**新建文件**: `Sources/AnyDoor/Models/KeyBinding.swift`

**数据模型**:
```swift
@Model
final class KeyBinding {
    @Attribute(.unique) var id: UUID
    var keyCode: Int           // macOS 虚拟键码 (例如 kVK_F1 = 122)
    var modifierFlags: Int     // 修饰键标志 (Cmd/Ctrl/Alt/Shift)
    var appBundleID: String    // 目标应用 Bundle ID
    var appName: String        // 目标应用显示名称
    var appPath: String        // 目标应用路径
    var isEnabled: Bool        // 是否启用
    var createdAt: Date

    // Transient: 可读的快捷键描述
    @Transient var displayKey: String { ... }
}
```

**验证**: Model 编译通过，可以在 Preview 中使用 in-memory container 测试

---

### Step 3: 键码映射工具

**目标**: 提供 macOS 虚拟键码与可读名称之间的映射

**新建文件**: `Sources/AnyDoor/Utilities/KeyCodeMap.swift`

**内容**:
- 覆盖常用按键: F1-F12, A-Z, 0-9, 方向键, 特殊键
- 提供 `keyCode -> String` 和 `String -> keyCode` 转换
- 提供修饰键标志的可读描述（⌘ ⌥ ⌃ ⇧）

---

### Step 4: 应用切换服务

**目标**: 实现应用的打开/隐藏/切换逻辑

**新建文件**: `Sources/AnyDoor/Services/AppSwitcher.swift`

**核心逻辑**:
```
toggleApp(bundleID):
  1. 检查应用是否在运行
     - 未运行 → 启动应用（NSWorkspace.shared.openApplication）
     - 运行中 → 检查是否为最前应用
       - 是最前应用 → 隐藏（app.hide()）
       - 不是最前应用 → 激活（app.activate()）
```

**API 使用**:
- `NSWorkspace.shared.runningApplications` — 查找运行中的应用
- `NSRunningApplication.activate()` — 激活应用
- `NSRunningApplication.hide()` — 隐藏应用
- `NSWorkspace.shared.openApplication(at:configuration:)` — 启动应用

---

### Step 5: 全局快捷键服务

**目标**: 使用 CGEvent tap 监听全局按键事件

**新建文件**: `Sources/AnyDoor/Services/HotkeyService.swift`

**实现要点**:
1. 创建 CGEvent tap 监听键盘事件
2. 匹配按键事件与已注册的快捷键绑定
3. 匹配成功时调用 AppSwitcher 切换应用
4. 匹配成功时消费事件（避免穿透）
5. 在应用启动时检查辅助功能权限（`AXIsProcessTrusted()`）
6. 权限不足时引导用户到系统设置

**关键代码结构**:
```swift
class HotkeyService {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var bindings: [KeyBinding] = []

    func start() { ... }
    func stop() { ... }
    func updateBindings(_ bindings: [KeyBinding]) { ... }
}
```

**注意事项**:
- CGEvent tap 的回调是 C 函数指针，需要通过 `Unmanaged` 传递 self
- 需要在主线程的 RunLoop 上添加事件源
- 需要处理权限被撤销的情况

---

### Step 6: 菜单栏视图

**目标**: 实现菜单栏弹出视图，显示快捷键列表和操作按钮

**新建文件**: `Sources/AnyDoor/Views/MenuBarView.swift`

**UI 设计**（Liquid Glass 风格）:
```
┌─────────────────────────────┐
│  AnyDoor                    │  ← 标题
├─────────────────────────────┤
│  F1  →  Safari              │  ← 快捷键列表
│  F2  →  Terminal            │     每行显示: 快捷键 + 应用名
│  F3  →  VS Code             │     使用 glassEffect
│  ⌘F4 →  Finder              │
├─────────────────────────────┤
│  ⚙️ 设置    ⏻ 退出          │  ← 操作按钮
│                             │     buttonStyle(.glass)
└─────────────────────────────┘
```

**实现要点**:
- 使用 `MenuBarExtra` 的 `window` 风格以支持自定义 SwiftUI 视图
- 使用 `@Query` 从 SwiftData 获取绑定列表
- 使用 `GlassEffectContainer` 包裹多个 glass 元素
- 设置按钮打开 Settings 窗口
- 退出按钮调用 `NSApplication.shared.terminate(nil)`

---

### Step 7: 设置窗口

**目标**: 实现设置页面，管理快捷键绑定

**新建文件**:
- `Sources/AnyDoor/Views/SettingsView.swift`
- `Sources/AnyDoor/Views/BindingListView.swift`
- `Sources/AnyDoor/Views/BindingEditView.swift`
- `Sources/AnyDoor/Views/GeneralSettingsView.swift`

**SettingsView**: 使用 `TabView` 分页
- 快捷键 Tab — `BindingListView`
- 通用 Tab — `GeneralSettingsView`（预留，暂无功能）

**BindingListView**:
- 使用 `Table` 或 `List` 显示所有绑定
- 支持添加（+按钮）、删除（-按钮/Delete键）、编辑（双击）
- 每行显示: 启用状态、快捷键、目标应用
- 使用 `@Query` 从 SwiftData 获取数据

**BindingEditView** (Sheet):
- 快捷键录入: 用户按下按键组合来录入快捷键（使用 NSEvent 局部监听）
- 应用选择: 使用 `NSOpenPanel` 选择 .app 文件，或从运行中应用列表选择
- 保存/取消按钮

**GeneralSettingsView** (预留):
- 开机自启动开关（预留）
- 其他设置占位

---

### Step 8: 集成与打磨

**目标**: 串联所有组件，确保整体工作

**任务**:
1. 在 App 入口正确初始化所有服务
2. HotkeyService 在绑定数据变化时自动更新
3. 菜单栏图标选择（使用 SF Symbol: `door.left.hand.open`）
4. 权限引导: 首次启动时检查辅助功能权限并提示
5. 确保应用在菜单栏驻留，不在 Dock 显示
6. 测试完整流程: 添加绑定 → 按快捷键 → 应用切换

---

## 风险与注意事项

1. **辅助功能权限**: CGEvent tap 需要辅助功能权限。SPM 构建的二进制没有 Info.plist，用户需要手动在系统设置中授权。
2. **Swift 6 并发安全**: SwiftData Model 需要 `@MainActor` 标记，CGEvent tap 回调在非主线程，需要注意线程安全。
3. **macOS 26 可用性**: Liquid Glass API 和部分 SwiftUI 特性需要 macOS 26+，当前需确认 Xcode 和 SDK 版本支持。
4. **键码兼容性**: 不同键盘布局的虚拟键码可能不同，初版仅支持标准美式键盘布局。

## 实现顺序

按步骤 1→8 顺序实现，每步完成后验证。核心功能优先级:
1. Step 1-2: 项目能跑起来 + 数据模型
2. Step 3-5: 核心功能（键码映射 + 应用切换 + 快捷键监听）
3. Step 6-7: UI（菜单栏 + 设置页面）
4. Step 8: 集成打磨
