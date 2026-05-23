# AnyDoor

[English](README.md)

AnyDoor 是一款 macOS 菜单栏应用，可以通过全局快捷键切换指定应用。

按一次快捷键打开或激活应用，再按一次隐藏应用。

## 环境要求

- macOS 26+ (Tahoe)
- Swift 6.2
- 辅助功能权限：系统设置 > 隐私与安全性 > 辅助功能

## 安装

```bash
git clone https://github.com/ZingerLittleBee/AnyDoor.git
cd AnyDoor
swift build -c release
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

### 打包相关命令

```bash
# 将本地发布变量加载到当前 shell。
set -a
source .env
set +a

# 只构建 release 二进制。
make swift-release

# 构建并安装 /Applications/AnyDoor.app，供本机使用。
make install

# 移除 /Applications/AnyDoor.app。
make uninstall

# 下载固定版本的 Sparkle 命令行工具。
make sparkle-tools

# 检查登录钥匙串里的 Developer ID 签名身份。
security find-identity -v -p codesigning

# 检查 notarytool keychain profile 是否可用。
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"

# 验证完整发布流水线，但不提交、不打 tag、不 push、不创建 GitHub Release。
make release-dryrun VERSION=1.0.1

# 发布经过签名和公证的正式版本。
make release VERSION=1.1.0
```

### 一次性机器配置

1. 复制 `.env.example` 为 `.env`，并填写本机发布变量。

   `.env` 只保留在本地，已经被 git 忽略，不要提交。

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
   set -a
   source .env
   set +a

   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
     --apple-id "$APPLE_ID" \
     --team-id "$APPLE_TEAM_ID"
   ```

   在安全提示里输入 Apple app-specific password。成功后，凭据会存入
   Keychain，并通过 `NOTARY_PROFILE` 引用。之后打包发布不再需要这个密码，
   也不应该继续把 `APPLE_APP_SPECIFIC_PASSWORD` 明文留在 `.env` 里。

4. 验证 notary profile：

   ```bash
   xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
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

```bash
set -a
source .env
set +a

make release-dryrun VERSION=1.0.1
```

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

set -a
source .env
set +a

make release VERSION=1.1.0
```

发布脚本会更新 `Info.plist` 版本，移动 changelog 条目，执行构建和
codesign，提交 Apple 公证，打包 DMG 和 zip，重新生成 Sparkle appcast，
提交 commit，打 tag，push，创建 GitHub draft release，上传产物，最后发布。

## 工作原理

- **CGEvent tap**：使用 HID 级别的 `.cghidEventTap`，在应用收到按键前拦截键盘事件。
- **SwiftData**：持久化快捷键绑定。
- **MenuBarExtra**：使用 `.window` 样式提供菜单栏面板。
- 应用以 accessory 模式运行，不显示 Dock 图标。

## 技术栈

- SwiftUI (`MenuBarExtra` + `Settings`)
- SwiftData
- CGEvent tap
- Swift Package Manager

## 许可证

MIT
