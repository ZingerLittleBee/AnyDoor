# AnyDoor

[English](README.md) | **简体中文**

[![Release](https://img.shields.io/github/v/release/ZingerLittleBee/AnyDoor?style=for-the-badge&cacheSeconds=3600)](https://github.com/ZingerLittleBee/AnyDoor/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/ZingerLittleBee/AnyDoor/total?style=for-the-badge&cacheSeconds=3600)](https://github.com/ZingerLittleBee/AnyDoor/releases)
[![License](https://img.shields.io/github/license/ZingerLittleBee/AnyDoor?style=for-the-badge&cacheSeconds=3600)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS_14+-000000?logo=apple&logoColor=white&style=for-the-badge)](https://www.apple.com/macos)
[![Built with Swift](https://img.shields.io/badge/built_with-Swift_6.2-F05138?logo=swift&logoColor=white&style=for-the-badge)](https://www.swift.org)

AnyDoor 是一款由全局快捷键驱动的 macOS 菜单栏控制中心。把任意键位组合绑定到
应用切换、文本翻译、系统开关或一次性动作，整个流程不需要离开键盘。

按一次快捷键打开或激活应用，再按一次隐藏。同样的肌肉记忆也可以用来静音、锁屏、
取色、对屏幕区域 OCR、翻译选中文本或屏幕文字、转换与压缩图片、截图与录屏——需要时还有剪贴板历史、
窗口布局、`/etc/hosts` 配置、外接显示器亮度、Hyper Key，以及 Spotlight 风格的
命令面板。

## 演示

<video src="https://github.com/user-attachments/assets/aba5cea1-c617-460f-90b1-5949578d1281" poster="https://github.com/ZingerLittleBee/AnyDoor/raw/main/landing/public/promo-zh.jpg" controls></video>

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
- 屏幕区域 OCR —— 通过 Vision 框架识别文字并写入剪贴板
- 扫描二维码 / 条形码 —— 识别屏幕上的码并把内容写入剪贴板
- 取色器 —— 调用系统取色器并把 HEX 写入剪贴板
- 翻译文本 —— 打开翻译窗口、翻译当前选中文本，或 OCR 屏幕区域后翻译识别出的文字

### 屏幕截图

- 一个截图菜单，一处选区：快捷键冻结屏幕并显示可预先调整的选区（缩放手柄、拖动、
  重新框选；记忆上次选区），下方贴附工具栏随手切换工具——**区域**、**窗口**、
  **全屏**、**滚动** 与 **录制**。
- 区域 / 窗口 / 全屏 / 定时截图，每种都可单独绑定快捷键；冻屏浮层带十字光标、
  实时尺寸、放大镜，并支持方向键微调 / 调整大小，覆盖所有已连接的显示器。
- **滚动截图** 应对超过一屏的内容：CleanShot X 式的交互会话——你向上或向下滚动目标，
  AnyDoor 实时抓帧并重叠对齐、像素级拼接，预览随之增长，底部是完成 / 取消工具栏；
  会话自身的窗口不会进入截图，并会复用上次的选区。
- 截图落地后停靠在屏幕左下角的 **快捷操作浮层**：可拖拽分享的缩略图，外加复制、
  保存、编辑、钉在屏幕上、OCR、重拍、删除（删除会同时从剪贴板历史移除）。
- **标注编辑器**：箭头、直线、矩形、椭圆、自由画笔、荧光笔、文字、模糊、像素化、
  遮挡条、序号标记，以及非破坏性裁剪——可逐工具设置颜色 / 线宽 / 填充，支持
  撤销 / 重做，并导出到 复制 / 保存 / 钉屏。
- 可把任意截图钉在屏幕上作为置顶悬浮参考。
- 截图设置：保存位置、文件名模板、自动保存 / 自动复制、定时延迟预设（3 / 5 / 10 秒），
  以及快捷操作浮层的超时时间。

### 屏幕录制

- 通过 AVFoundation 把全屏或所选区域录制为 **MOV**、**MP4** 或动图 **GIF**，
  可配置帧率，并可选光标捕获、麦克风音频、可拖拽的摄像头浮层与屏上按键显示。
- 浮动控制条显示已录时长，带暂停 / 继续与停止；完成后按所选格式导出并在访达中显示。
- 不采集系统（应用）音频——仅录制麦克风。

### 剪贴板历史

- 后台监听记录复制到剪贴板的文字、图片和文件，并提供可搜索的 Liquid Glass「墙」浏览与重新粘贴。
- 对捕获的图片识别文字（OCR）、条形码和颜色。
- 按来源排除 —— 跳过密码管理器等指定应用的历史，排除项会随备份一起携带。

### 翻译

- 翻译手动输入的文本、当前选中文本，或从屏幕区域 OCR 出来的文字。
- 多服务并排输出：Apple 本机翻译、Google、Bing、DeepL / DeepLX，以及 OpenAI-compatible
  服务，例如 OpenAI、DeepSeek、通义千问 Qwen、Gemini、Kimi、智谱 GLM、OpenRouter、
  Ollama 或自定义 endpoint。
- 可设置默认目标语言和第二目标语言；当源语言与目标语言相同时，AnyDoor 会自动切换到第二目标语言。
- 每个服务的 API key 存在 Keychain；服务定义、排序、prompt template、额外请求 body / headers、
  以及「展开后再翻译」模式可在设置中调整。
- 在支持的 macOS 版本上，Apple 翻译可在翻译设置页下载所需语言包。
- 翻译历史会把同一次运行中各 provider 的结果合并成一组，支持收藏、复制、重新翻译、保留数量裁剪和清空。
- 支持朗读原文或译文，也可开启自动朗读第一个成功结果。
- 读取选中文本的剪贴板 fallback 会保留用户完整剪贴板内容，并避免 AnyDoor 的临时复制 / 恢复写入进入剪贴板历史。

### 图片转换

- 独立的工作区窗口——可绑定全局快捷键，打开时会把当前 Finder 选中的图片带进待转列表；
  可折叠侧栏（⌘B）承载待转 / 转换记录切换，中间是原图 / 结果对比画布，底部是控制条。
- 通过拖拽、⌘O 或 ⌘V（复制的图片文件或位图）添加图片。
- **格式模式** 可转换为 PNG、JPEG、HEIC、AVIF、WebP、TIFF、GIF、BMP、PDF 或 ICO，
  并提供精确的实时结果预览——与实际运行产出完全相同的字节，随质量滑杆实时更新。
- **目标体积模式** 在保持源格式不变的前提下压缩到指定体积：JPEG / HEIC / AVIF / WebP
  通过有界的质量搜索，PNG 通过缩小尺寸，缩小也始终作为所有格式的兜底手段
  （最长边下限 640 px）。WebP 输出由内置的 libwebp 编码。已经小于目标的源文件
  会原样直出（字节不变）；无法达到目标时显示明确的横幅，可选择「仍然保存」尽力结果。
- 「全部转换」会先询问保存位置并记住所选文件夹；转换过程可随时取消（⌘.）。
- 转换记录保存每次转换的格式、输出文件体积和时间，并提供「在访达中显示」与复制操作。

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
- 内联换算：输入换算表达式即可在顶部看到结果，按回车复制。单位（长度、质量、温度、数据大小、速度）
  如 `3 ft to m` / `72 f to c` / `1 gb to mib`；时区如 `3pm tokyo` / `9am london to tokyo`；
  汇率如 `100 usd to eur`（也支持 `$` / `€` / `£`、`rmb` / `yuan` / `euro` 等俗称，以及 `=` 连接符），
  汇率取自 Frankfurter 的 ECB 数据，每天缓存一次、可离线使用。底部仅在汇率场景出现的工具条可按需刷新汇率表。
- 内联开发者工具：`base64`、`url`，以及 `md5` / `sha1` / `sha256` 对其余输入做编码或哈希；
  粘贴 JSON 可美化 / 压缩，粘贴 Unix 时间戳可渲染本地 / UTC / ISO 8601。Raycast 风格的范围徽章
  会把关键词收进搜索框胶囊，让列表只显示该工具的结果。

### 快速入口（Quicklinks）

- 自定义命令面板条目，可打开网址、文件或文件夹、App 深链，或带 `{query}` 占位符的
  搜索模板。编辑器的「类型」选择器会按类型调整输入提示，并为文件 / 文件夹提供原生
  选择器，不用手打路径就能选目录。
- 搜索模板支持内联参数（`gh AnyDoor`）；输入模板关键词后按 Tab 会把它收成搜索框里
  的徽章，之后只需输入查询内容，空输入框按 Backspace 可去掉徽章。
- 可为条目设置关键词以在面板中直接唤起，或绑定全局快捷键——普通链接直接打开，
  搜索模板则进入参数输入模式。
- 可指定「打开方式」覆盖默认处理程序（该 App 不存在时回退到系统默认）；图标取自
  指定 App、文件 / 文件夹元数据、深链处理程序或缓存的网站 favicon。
- 支持拖拽排序、切换可见性，整套配置参与备份 / 同步。内置一组常用模板（Google、
  GitHub、YouTube、Stack Overflow、npm、MDN、Google 翻译、ChatGPT）开箱即用。

### 菜单栏面板

- 点击菜单栏图标弹出 Liquid Glass 面板，显示每个启用项的当前状态和快捷键。
- 悬停 App Shortcuts 或 Port Manager 行打开侧边浮窗。
- OCR / 取色器执行后弹出 toast 反馈结果。
- 有新版本时面板内显示更新横幅。

### 设置

- **面板** 标签页：拖拽排序（顶层项与应用快捷键 / 窗口布局子项均可）、单项可见性、内联快捷键录入、类型徽章（开关 / 动作 / 子菜单）。
- **快速入口** 标签页：创建 / 编辑命令面板条目，含链接类型选择器、关键词、打开方式覆盖、快捷键与可见性，支持拖拽排序。
- **剪贴板** 标签页：历史监听、仅复制模式、保留时长、按来源排除应用，以及清空全部历史。
- **截图** 标签页：保存位置、文件名模板、自动保存 / 自动复制、定时延迟预设、快捷操作浮层超时，以及录制选项。
- **翻译** 标签页：目标语言、自动朗读、服务排序、provider / API key 配置、Apple 语言包下载，以及历史保留数量。
- **通用** 标签页：开机自启、语言、菜单栏图标样式、Hyper Key、命令面板快捷键、定时关机、辅助功能 / 自动化 / 屏幕录制权限状态及一键申请、配置备份与恢复，以及自动更新配置。

### 自动更新

- 集成 Sparkle，使用 EdDSA 签名的 appcast。
- 可配置检查频率（每天 / 每周 / 关闭），支持手动检查。
- 更新横幅直接出现在菜单栏面板里。

### 备份与恢复

- 把应用快捷键、内置项偏好、剪贴板 / 截图设置、翻译目标语言、自动朗读、服务定义，以及白名单内的通用设置导出为带版本号的快照，并在另一台 Mac 上导入。
- 剪贴板历史、翻译历史、API keys 和机器相关的键不会导出；导入时按 bundle ID 重新解析应用路径，改动无需重启即可生效。

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
- **翻译协调器**：把请求分发给启用的 provider，按 run 记录历史，并屏蔽被新请求取代的过期异步结果。
- 应用以 accessory 模式运行，不显示 Dock 图标。

## 技术栈

- SwiftUI `Settings` 场景 + AppKit 菜单栏（`NSStatusItem` + `NSPanel`）
- SwiftData
- CGEvent tap（`.cghidEventTap`）
- 写入 `/etc/hosts` 的特权 XPC 助手
- Vision OCR、Natural Language 检测、AVFoundation 朗读，以及可用时的 Apple Translation framework
- Swift Package Manager

## 参与贡献

欢迎贡献！开发环境搭建、代码规范和 PR 流程见 [CONTRIBUTING.md](CONTRIBUTING.md)（英文）。较大的改动请先开 issue 讨论。

## 致谢

捆绑的第三方代码，完整许可证文本见 [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md)。

- [MonitorControl](https://github.com/MonitorControl/MonitorControl)（MIT）—— 其 `IntelDDC` 被内置用于 Intel Mac 上外接显示器的 DDC/CI 亮度控制（本身改编自 [@reitermarkus](https://github.com/reitermarkus) 的工作）。
- [Sparkle](https://sparkle-project.org/)（MIT）—— 应用自动更新。
- [AskForPermission](https://github.com/riko2chen/AskForPermission)（MIT）—— macOS 辅助功能权限助手。
- [libwebp](https://chromium.googlesource.com/webm/libwebp)（BSD-3-Clause）—— 为图片转换提供 WebP 编码（经由 SDWebImage/libwebp-Xcode）；macOS 原生只能解码 WebP，无法编码。

## 许可证

MIT
