// Copy for the hero (§ 00) and the "Why AnyDoor" datasheet (§ 01). The hotkey
// unit's copy and demo data live in hotkey.ts because its client script imports
// them.
import type { Bi } from '../i18n';

export const hero = {
  // Spec strip above the eyebrow. The revision is appended from the appcast.
  model: 'Model AD-1',
  rev: 'Rev ',
  system: 'macOS 14+',
  arch: 'Universal',
  eyebrow: { zh: '一颗按键，一扇任意门', en: 'One key. Any door.' },
  h1a: { zh: '每个 App、', en: 'Every app,' },
  h1b: { zh: '每个系统开关，', en: 'every toggle,' },
  h1c: { zh: '一键直达。', en: 'one key away.' },
  lede: {
    zh: 'AnyDoor 是为离不开键盘的开发者打造的 macOS 菜单栏控制中心。绑定任意按键来唤起 App、翻转系统开关、管理端口与 Hosts、运行内置动作。按键在 HID 层截获，快过你的肌肉记忆，双手永不离开键盘。',
    en: 'AnyDoor is a macOS menu bar control center for developers who live on the keyboard. Bind any key to launch and toggle apps, flip system settings, manage ports and hosts, or run built-in actions. Keys are captured at the HID level, so your hands never leave the keyboard.',
  },
  // The version is appended at render time from the appcast.
  ctaPrimary: { zh: '下载 v', en: 'Download v' },
  ctaSecondary: { zh: '在 GitHub 上查看', en: 'View on GitHub' },
  meta: [
    { zh: '免费 & 开源', en: 'Free & open source' },
    { zh: 'macOS 14+', en: 'macOS 14+' },
    { zh: 'MIT 协议', en: 'MIT License' },
  ] as Bi[],
};

export interface WhyColumn {
  title: Bi;
  desc: Bi;
  vs: Bi;
}

export const why = {
  eyebrow: { zh: '为什么选 AnyDoor', en: 'Why AnyDoor' },
  h2a: { zh: '启动器负责搜索，', en: 'Launchers search.' },
  h2b: { zh: 'AnyDoor 控制整台 Mac。', en: 'AnyDoor controls your Mac.' },
  lede: {
    zh: '启动器把应用和命令放到了眼前；AnyDoor 把整台 Mac 也放了进来：端口、Hosts、显示器亮度、系统开关，一套热键直达。免费、开源、纯本地。',
    en: 'Launchers bring your apps and commands within a keystroke. AnyDoor brings the rest of your Mac too: ports, hosts, display brightness, system toggles, all under one set of hotkeys. Free, open source, fully local.',
  },
  columns: [
    {
      title: { zh: '免费 & 开源', en: 'Free & open source' },
      desc: {
        zh: 'MIT 协议，没有付费墙、没有 Pro 版本、没有订阅。所有功能开箱即用，源码完全可审计。',
        en: 'MIT-licensed. No paywall, no Pro tier, no subscription. Every feature is here from day one, and the source is yours to audit.',
      },
      vs: { zh: 'MIT · 永久免费', en: 'MIT · free forever' },
    },
    {
      title: { zh: '纯本地，无账号', en: 'Local, no account' },
      desc: {
        zh: '完全在设备上运行，没有遥测、没有统计，也不用注册账号。你的数据从不离开这台 Mac。',
        en: 'Runs entirely on-device. No telemetry, no analytics, no account to register. Your data never leaves this Mac.',
      },
      vs: { zh: '无遥测 · 无账号', en: 'No telemetry · no account' },
    },
    {
      title: { zh: '系统级控制', en: 'System-level control' },
      desc: {
        zh: '端口管理、Hosts 编辑、外接显示器亮度（DDC）、系统开关，这些深入系统的控制，一套热键直达。',
        en: 'Port management, hosts editing, external-display brightness (DDC), system toggles: deep, system-level control, one hotkey away.',
      },
      vs: { zh: '端口 · Hosts · 亮度', en: 'Ports · hosts · brightness' },
    },
  ] as WhyColumn[],
};
