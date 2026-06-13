# AnyDoor

[English](README.md)

AnyDoor 是一款由全局快捷键驱动的 macOS 菜单栏控制中心。把任意键位组合绑定到
应用切换、系统开关或一次性动作，整个流程不需要离开键盘。

按一次快捷键打开或激活应用，再按一次隐藏。同样的肌肉记忆也可以用来静音、锁屏、
取色、对屏幕区域 OCR——需要时还有剪贴板历史、窗口布局、`/etc/hosts` 配置、
外接显示器亮度、Hyper Key，以及 Spotlight 风格的命令面板。

## 功能

### 应用快捷键

- 每个应用绑定一个全局快捷键：未运行时打开，已运行但在后台时激活，已在前台时隐藏。
- 内联快捷键录入器，实时检测修饰键，冲突时提示替换。
- 支持拖拽排序，可单独切换每一项的可见性。

### 内置系统开关

| 开关 | 说明 |
| --- | --- |
| Keep Awake | 通过 `IOPMAssertion` 阻止显示器/系统休眠 |
| Mute Audio | 通过 Core Audio 切换默认输出设备的静音状态 |
| Dark Mode | 用 AppleScript 切换系统外观 |
| Hide Desktop Icons | 切换 Finder 桌面图标显示 |
| Show Hidden Files | 切换 Finder `AppleShowAllFiles` |
| Hide Dock | 切换 Dock 自动隐藏 |
| Auto-hide Menu Bar | 切换菜单栏自动隐藏 |
| Keyboard Lock | 屏蔽除已注册快捷键外的所有按键（清洁键盘模式） |

### 内置动作

- 锁屏、显示器休眠、系统休眠
- 清空废纸篓、刷新 DNS 缓存
- 重启 Finder / Dock / SystemUIServer + ControlCenter
- 截图到剪贴板（交互式区域截图）
- 屏幕区域 OCR —— 通过 Vision 框架识别文字并写入剪贴板
- 扫描二维码 / 条形码 —— 识别屏幕上的码并把内容写入剪贴板
- 取色器 —— 调用系统取色器并把 HEX 写入剪贴板

### 剪贴板历史

- 后台监听记录复制到剪贴板的文字、图片和文件，并提供可搜索的 Liquid Glass「墙」浏览与重新粘贴。
- 对捕获的图片识别文字（OCR）、条形码和颜色。
- 按来源排除 —— 跳过密码管理器等指定应用的历史，排除项会随备份一起携带。

### 窗口布局

- 把当前窗口平铺为二分之一、三分之一、三分之二、四分之一、居中或最大化，每种都可单独绑定快捷键。
- 把当前窗口移动到下一个 / 上一个显示器。
- 面板里的「窗口布局」子菜单列出所有排列方式。

### 外接显示器亮度

- 通过 VCP `0x10` 对外接显示器做 DDC/CI 亮度控制，并显示屏幕 OSD。
- 按架构选择后端（Apple Silicon / Intel），提供全局亮度增减快捷键。

### Hosts 管理

- 用内置编辑器修改 `/etc/hosts`，支持多套命名配置和一键切换。
- 写入通过特权 XPC 助手（`SMAppService` 守护进程）完成；未安装助手时回退到管理员授权的 AppleScript。

### Hyper Key

- 通过 `hidutil` 把 Caps Lock（或其他触发键）重映射为 Hyper 修饰键（Control + Option + Command，可选 Shift）。
- 轻点一下可触发独立动作（无 / Escape / 原始按键）；watchdog 会重新应用映射，并在关机时清除。

### 定时关机

- 设定一次性延时关机，重启后仍然生效，Mac 唤醒后会重新校验。
- 触发前弹出可取消的警告面板；执行方式可为优雅关机（System Events）或强制关机（特权助手）。

### 端口管理

- 列出当前系统监听的所有端口的子菜单。
- 支持按端口号或进程名搜索。
- 平铺列表和按进程分组的树形视图。
- 扫描失败可一键重试，支持实时刷新。

### 命令面板

- Spotlight 风格的启动器（全局快捷键），在一处搜索并执行任意命令、应用、内置项或监听端口。
- 内联计算器：输入数学表达式即可在顶部看到结果，按回车复制。支持四则运算、括号、幂运算（`^`）、
  百分比字面量（`1234 * 8%`）、常量 `pi` / `e`，以及科学函数（`sqrt`、`sin`、`log`、`pow` 等；
  三角函数按弧度）。纯数字仍走端口搜索；以 `=` 前缀可强制计算（如 `=8080`）。

### 菜单栏面板

- 点击菜单栏图标弹出 Liquid Glass 面板，显示每个启用项的当前状态和快捷键。
- 悬停 App Shortcuts 或 Port Manager 行打开侧边浮窗。
- OCR / 取色器执行后弹出 toast 反馈结果。
- 有新版本时面板内显示更新横幅。

### 设置

- **面板** 标签页：拖拽排序、单项可见性、内联快捷键录入、类型徽章（开关 / 动作 / 子菜单）。
- **通用** 标签页：开机自启、菜单栏图标样式、辅助功能与自动化权限状态及一键申请、自动更新配置、配置备份与恢复。

### 自动更新

- 集成 Sparkle，使用 EdDSA 签名的 appcast。
- 可配置检查频率（每天 / 每周 / 关闭），支持手动检查。
- 更新横幅直接出现在菜单栏面板里。

### 备份与恢复

- 把应用快捷键、内置项偏好和白名单内的通用设置导出为带版本号的快照，并在另一台 Mac 上导入。
- 剪贴板历史和机器相关的键不会导出；导入时按 bundle ID 重新解析应用路径，改动无需重启即可生效。

### 安全与权限

- 以 `.accessory` 模式运行（无 Dock 图标）。
- 辅助功能和自动化权限流程内置在设置里，带实时状态指示。
- CGEvent tap 工作在 HID 层级，watchdog 会在系统因回调超时禁用 tap 时自动重启。

## 环境要求

- macOS 14 (Sonoma) 或更高版本
- Liquid Glass 效果只在 macOS 26 (Tahoe) 启用；macOS 14–25 会回退到普通材质背景。
- Swift 6.2
- 辅助功能权限：系统设置 > 隐私与安全性 > 辅助功能

## 安装

```bash
git clone https://github.com/ZingerLittleBee/AnyDoor.git
cd AnyDoor
make install
```

这会构建 release 二进制，并安装带有 bundle metadata 和图标的
`/Applications/AnyDoor.app`。

如果只想构建二进制：

```bash
make swift-release
```

构建产物在：

```bash
.build/release/AnyDoor
```

## 使用

1. 运行 AnyDoor，菜单栏会显示应用图标。
2. 点击菜单栏图标，进入 **设置**。
3. 点击 **+** 添加绑定：
   - 点击快捷键输入框并按下想要的组合键。
   - 点击 **选择...** 选择目标应用。
   - 点击 **保存**。
4. 按快捷键切换应用：未运行则打开，已在前台则隐藏，否则激活。

## 开发

```bash
# 热重载开发模式，需要 watchexec
make

# 调试构建
make build

# 只构建 release 二进制，不发布
make swift-release
```

## 发布打包

发布流程会使用 Developer ID 签名，提交 Apple 公证，打包 DMG 和 Sparkle
更新 zip，然后创建 GitHub Release 并更新 appcast。
发布相关的 Make target 会通过 `bash` 自动加载 `.env`，所以同一组命令可以在
fish、zsh、bash 或 sh 里直接使用。

### 打包相关命令

```bash
# 只构建 release 二进制。
make swift-release

# 构建并安装 /Applications/AnyDoor.app，供本机使用。
make install

# 移除 /Applications/AnyDoor.app。
make uninstall

# 下载固定版本的 Sparkle 命令行工具。
make sparkle-tools

# 从 .env 创建或更新 notarytool keychain profile。
make notary-profile

# 检查登录钥匙串里的 Developer ID 签名身份。
security find-identity -v -p codesigning

# 从 .env 检查 notarytool keychain profile 是否可用。
make notary-check

# 验证完整发布流水线，但不提交、不打 tag、不 push、不创建 GitHub Release。
make release-dryrun 1.0.1

# 不传版本时，会基于 Info.plist 当前版本自动递增 patch。
make release-dryrun

# 发布经过签名和公证的正式版本。
make release 1.1.0
```

### 一次性机器配置

1. 复制 `.env.example` 为 `.env`，并填写本机发布变量。

   `.env` 只保留在本地，已经被 git 忽略，不要提交。
   需要填写 `APPLE_ID`、`APPLE_TEAM_ID`、`NOTARY_PROFILE`、
   `SIGNING_IDENTITY` 和 `REPO_URL`。notary profile 存入 Keychain 后，
   `APPLE_APP_SPECIFIC_PASSWORD` 应该保持为空。

2. 确认登录钥匙串里有 Developer ID 签名身份：

   ```bash
   security find-identity -v -p codesigning
   ```

   当前期望的身份是：

   ```bash
   Developer ID Application: Bee Zinger (9VM4RM39R3)
   ```

3. 如果还没有 notarytool keychain profile，先创建它：

   ```bash
   make notary-profile
   ```

   在安全提示里输入 Apple app-specific password。成功后，凭据会存入
   Keychain，并通过 `NOTARY_PROFILE` 引用。之后打包发布不再需要这个密码，
   也不应该继续把 `APPLE_APP_SPECIFIC_PASSWORD` 明文留在 `.env` 里。

4. 验证 notary profile：

   ```bash
   make notary-check
   ```

5. 安装本地发布工具：

   ```bash
   brew install create-dmg
   make sparkle-tools
   ```

6. 确认 GitHub CLI 已登录：

   ```bash
   gh auth status -h github.com
   ```

### Dry run

每次正式发布前都先跑一次 dry run。它会完成签名、公证、DMG 打包、Sparkle
zip 签名和 `appcast.xml` 生成，但会在提交 commit、打 tag、push、创建
GitHub Release 之前停止。

dry run 使用和正式发布相同的 preflight：需要在干净的 `main` 分支上执行，
并且本地 `main` 要与 `origin/main` 保持同步。

```bash
make release-dryrun 1.0.1
```

如果不传版本，脚本会基于当前 `CFBundleShortVersionString` 自动递增 patch。
当前版本必须已经是严格的 `MAJOR.MINOR.PATCH`。

预期输出包括：

- `dist/AnyDoor.app`
- `dist/AnyDoor-1.0.1.zip`
- `dist/AnyDoor-1.0.1.dmg`
- `appcast.xml`

### 正式发布

正式发布必须在干净的 `main` 分支上执行，并且本地 `main` 要与 `origin/main`
保持同步。`CHANGELOG.md` 的 `## [Unreleased]` 小节必须有内容。

```bash
git checkout main
git pull --ff-only origin main

make release 1.1.0
```

正式发布建议显式传入版本号。

发布脚本会更新 `Info.plist` 版本，移动 changelog 条目，执行构建和
codesign，提交 Apple 公证，打包 DMG 和 zip，重新生成 Sparkle appcast，
提交 commit，打 tag，push，创建 GitHub draft release，上传产物，最后发布。

## 工作原理

- **CGEvent tap**：使用 HID 级别的 `.cghidEventTap`，在应用收到按键前拦截键盘事件。
- **SwiftData**：持久化快捷键绑定。
- **AppKit 菜单栏**：由 `NSStatusItem` 加一个浮动 `NSPanel` 实现（`MenuBarController` 管理），而非 SwiftUI 的 `MenuBarExtra`。
- **特权 XPC 助手**：在校验调用方代码签名后写入 `/etc/hosts`。
- 应用以 accessory 模式运行，不显示 Dock 图标。

## 技术栈

- SwiftUI `Settings` 场景 + AppKit 菜单栏（`NSStatusItem` + `NSPanel`）
- SwiftData
- CGEvent tap（`.cghidEventTap`）
- 写入 `/etc/hosts` 的特权 XPC 助手
- Swift Package Manager

## 致谢

捆绑的第三方代码，完整许可证文本见 [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)。

- [MonitorControl](https://github.com/MonitorControl/MonitorControl)（MIT）—— 其 `IntelDDC` 被内置用于 Intel Mac 上外接显示器的 DDC/CI 亮度控制（本身改编自 [@reitermarkus](https://github.com/reitermarkus) 的工作）。
- [Sparkle](https://sparkle-project.org/)（MIT）—— 应用自动更新。
- [AskForPermission](https://github.com/riko2chen/AskForPermission)（MIT）—— macOS 辅助功能权限助手。

## 许可证

MIT
