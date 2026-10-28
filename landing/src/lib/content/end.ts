// Copy for the closing sections: Download, FAQ, and the footer.
import type { Bi } from '../i18n';
import { RELEASES, REPO } from '../repo';

export interface Faq {
  q: Bi;
  a: Bi;
}

export interface Spec {
  label: Bi;
  value: Bi;
}

export const download = {
  eyebrow: { zh: '下载', en: 'Download' },
  h2a: { zh: '准备好了吗？', en: 'Ready when' },
  h2b: { zh: '按下这颗键。', en: 'you are.' },
  lede: {
    zh: '免费、开源、纯本地运行，没有遥测，不需要账号。签名 + 公证的安装包，集成 Sparkle 自动更新。',
    en: 'Free, open source, runs entirely locally. No telemetry, no account. A signed + notarized installer with Sparkle auto-update built in.',
  },
  // The version is appended at render time from the appcast.
  dmgBtn: { zh: '下载 AnyDoor v', en: 'Download AnyDoor v' },
  channel: 'Stable',
  ghBtn: 'GitHub',
  srcTitle: { zh: '或者用源码构建', en: 'Or build from source' },
  srcDesc: { zh: '从源码构建并安装到 /Applications。', en: 'Build the release binary and install it to /Applications.' },
  // Shell lines shown in the terminal and written by the copy button.
  commands: [`git clone ${REPO}.git`, 'cd AnyDoor', 'make swift-release && make install'],
  result: '# → /Applications/AnyDoor.app',
  copy: { zh: '复制', en: 'Copy' },
  copied: { zh: '已复制', en: 'Copied' },
  copyFail: { zh: '请手动复制', en: 'Select to copy' },
  copyAria: { zh: '复制构建命令', en: 'Copy the build commands' },
  termTitle: 'zsh · AnyDoor',
  specs: [
    { label: { zh: '系统', en: 'System' }, value: { zh: 'macOS 14+', en: 'macOS 14+' } },
    { label: { zh: '架构', en: 'Architecture' }, value: { zh: 'Universal Binary', en: 'Universal Binary' } },
    { label: { zh: '安装包', en: 'Installer' }, value: { zh: '签名 + 公证', en: 'Signed + notarized' } },
    { label: { zh: '更新', en: 'Updates' }, value: { zh: 'Sparkle', en: 'Sparkle' } },
  ] as Spec[],
};

export const faq = {
  h2a: { zh: '常见', en: 'Some common' },
  h2b: { zh: '问题。', en: 'questions.' },
  lede: { zh: '没找到答案？到 GitHub 提一个 Issue。', en: 'Didn’t find it? Open an issue on GitHub.' },
  items: [
    {
      q: { zh: 'AnyDoor 是永久免费的吗？', en: 'Is AnyDoor really free?' },
      a: {
        zh: '是。AnyDoor 采用 MIT 协议，完全免费、开源，没有付费墙、订阅或 Pro 版本，所有功能开箱即用。',
        en: 'Yes. AnyDoor is MIT-licensed: completely free and open source, with no paywall, subscription, or Pro tier. Every feature is available from day one.',
      },
    },
    {
      q: { zh: 'AnyDoor 收集任何数据吗？', en: 'Does AnyDoor collect any data?' },
      a: {
        zh: '不。AnyDoor 完全在本地运行，没有任何遥测、统计或网络回传，也不需要账号登录。源码 100% 开源、可审计。',
        en: 'No. AnyDoor runs entirely on-device: no telemetry, no analytics, no network callbacks, and no account to sign in to. The source is 100% open and auditable.',
      },
    },
    {
      q: { zh: '和 Raycast、Alfred 有什么不同？', en: 'How is this different from Raycast or Alfred?' },
      a: {
        zh: '启动器擅长搜索与命令；AnyDoor 走得更深，把 App 切换、系统开关、端口管理、Hosts 编辑、外接显示器亮度（DDC）、剪贴板历史都收进同一套热键，是一层更贴近系统的控制。而且免费、开源、纯本地。',
        en: 'Launchers are great at search and commands; AnyDoor goes deeper. It folds app toggling, system switches, port management, hosts editing, external-display brightness (DDC), and clipboard history into one set of hotkeys, a layer of control closer to the system itself. And it’s free, open source, and fully local.',
      },
    },
    {
      q: { zh: '为什么需要辅助功能权限？', en: 'Why does it need accessibility permission?' },
      a: {
        zh: 'AnyDoor 通过 CGEvent tap 在 HID 层截获键盘事件，这是 macOS 实现全局热键的标准方式。所有事件处理都在本地完成，不会离开你的设备。',
        en: 'AnyDoor uses a CGEvent tap at the HID level to intercept keyboard events, the standard macOS path for global hotkeys. All event handling stays on your device.',
      },
    },
    {
      q: { zh: '会被 Gatekeeper 拦截吗？', en: 'Will Gatekeeper block it?' },
      a: {
        zh: '不会。.dmg 经过苹果开发者证书签名并公证（notarized），双击即可打开，不会弹出“无法验证开发者”的警告。',
        en: 'No. The .dmg is signed with an Apple Developer certificate and notarized, so it opens with a double-click, with no “unidentified developer” warning.',
      },
    },
    {
      q: { zh: '支持 Intel Mac 吗？', en: 'Does it work on Intel Macs?' },
      a: {
        zh: '支持。安装包是 Universal Binary，原生运行于 Apple Silicon 与 Intel；外接显示器亮度会按架构自动选择 DDC 后端。',
        en: 'Yes. The build is a Universal Binary that runs natively on both Apple Silicon and Intel; the external-display brightness backend is chosen automatically per architecture.',
      },
    },
    {
      q: { zh: 'Liquid Glass 在我的 macOS 上能看到吗？', en: 'Will I see Liquid Glass on my macOS?' },
      a: {
        zh: 'Liquid Glass 效果在 macOS 26（Tahoe）上完整启用；macOS 14–25 会自动降级为标准的菜单材质，功能完全相同。',
        en: 'Liquid Glass effects light up on macOS 26 (Tahoe); macOS 14–25 fall back to the standard menu material, with the same features and behavior.',
      },
    },
    {
      q: { zh: '我可以自己从源码构建吗？', en: 'Can I build it from source myself?' },
      a: {
        zh: '可以。make swift-release 构建二进制，make install 把它装进 /Applications。正式版由 GitHub Actions 从发布 tag 构建、签名、公证，发布到 GitHub Releases 并更新 Sparkle appcast。',
        en: 'Yes. make swift-release builds the binary and make install installs it in /Applications. Official releases are built, signed, and notarized by GitHub Actions from a release tag, then published to GitHub Releases along with the Sparkle appcast.',
      },
    },
  ] as Faq[],
};

export const footer = {
  links: [
    { label: 'GitHub', href: REPO },
    { label: 'Releases', href: RELEASES },
    { label: 'CHANGELOG', href: `${REPO}/blob/main/CHANGELOG.md` },
    { label: 'MIT License', href: `${REPO}/blob/main/LICENSE` },
  ],
  tagline: { zh: '一颗按键，一扇任意门。', en: 'One key. Any door.' },
  linksAria: { zh: '页脚链接', en: 'Footer links' },
  // Package.swift declares swift-tools-version 6.2.
  built: 'Made with Swift 6.2 in 2026.',
  part: 'AD-1 · anydoor.dev',
};
