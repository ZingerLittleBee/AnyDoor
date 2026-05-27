// Data tables — panel items, sample ports, hotkey apps, settings rows, toggle cards.

import type { Bi } from './copy';

// Menu-panel rows (mirror the AnyDoor screenshots, all 22 items).
export type PanelItem = {
  key: string;
  type: 'submenu' | 'toggle' | 'action';
  icon: string;            // key into icons.ts
  label: Bi;
  sub?: Bi;
  hotkey?: string[];        // displayed key glyphs
};

export const panelItems: PanelItem[] = [
  { key: 'shortcuts',    type: 'submenu', icon: 'keyboard',   label: { zh: '应用快捷键', en: 'App Shortcuts' }, sub: { zh: '2 个绑定', en: '2 bindings' } },
  { key: 'ports',        type: 'submenu', icon: 'globe',      label: { zh: '端口管理', en: 'Port Manager' } },
  { key: 'keepAwake',    type: 'toggle',  icon: 'coffee',     label: { zh: 'Keep Awake', en: 'Keep Awake' } },
  { key: 'mute',         type: 'toggle',  icon: 'mute',       label: { zh: '静音', en: 'Mute' } },
  { key: 'hideDesk',     type: 'toggle',  icon: 'hideDesk',   label: { zh: '隐藏桌面图标', en: 'Hide Desktop' } },
  { key: 'showHidden',   type: 'toggle',  icon: 'eye',        label: { zh: '显示隐藏文件', en: 'Show Hidden Files' } },
  { key: 'dark',         type: 'toggle',  icon: 'moon',       label: { zh: '深色模式', en: 'Dark Mode' } },
  { key: 'lock',         type: 'action',  icon: 'lock',       label: { zh: '锁定屏幕', en: 'Lock Screen' } },
  { key: 'trash',        type: 'action',  icon: 'trash',      label: { zh: '清空废纸篓', en: 'Empty Trash' } },
  { key: 'screenshot',   type: 'action',  icon: 'camera',     label: { zh: '截图到剪贴板', en: 'Screenshot to Clipboard' } },
  { key: 'displaySleep', type: 'action',  icon: 'sleepZ',     label: { zh: '显示器睡眠', en: 'Display Sleep' } },
  { key: 'systemSleep',  type: 'action',  icon: 'moon',       label: { zh: '系统休眠', en: 'System Sleep' } },
  { key: 'hideDock',     type: 'toggle',  icon: 'dock',       label: { zh: '隐藏 Dock', en: 'Hide Dock' } },
  { key: 'hideMenubar',  type: 'toggle',  icon: 'menubar',    label: { zh: '自动隐藏菜单栏', en: 'Auto-hide Menu Bar' } },
  { key: 'restartFinder',type: 'action',  icon: 'finder',     label: { zh: '重启访达', en: 'Restart Finder' } },
  { key: 'restartDock',  type: 'action',  icon: 'restart',    label: { zh: '重启 Dock', en: 'Restart Dock' } },
  { key: 'restartMB',    type: 'action',  icon: 'upload',     label: { zh: '重启菜单栏', en: 'Restart Menu Bar' } },
  { key: 'flushDNS',     type: 'action',  icon: 'refreshDNS', label: { zh: '刷新 DNS', en: 'Flush DNS' } },
  { key: 'kbLock',       type: 'toggle',  icon: 'keyOff',     label: { zh: '禁用键盘', en: 'Keyboard Lock' } },
  { key: 'ocr',          type: 'action',  icon: 'ocr',        label: { zh: '屏幕取词', en: 'Screen OCR' }, hotkey: ['⇧', '⌘', '2'] },
  { key: 'pickColor',    type: 'action',  icon: 'eyedropper', label: { zh: '屏幕取色', en: 'Pick Color' } },
  { key: 'qr',           type: 'action',  icon: 'qr',         label: { zh: '识别二维码', en: 'Scan QR Code' } },
];

// Toggles defaulted on
export const defaultOnToggles: Record<string, boolean> = {
  dark: true,
  hideDock: true,
};

// Sample ports — generic services, no exposed app names.
export type Port = { port: number; name: string; pid: number };
export const samplePorts: Port[] = [
  { port: 3000,  name: 'node',        pid: 1024 },
  { port: 5173,  name: 'vite',        pid: 2156 },
  { port: 5432,  name: 'postgres',    pid: 487  },
  { port: 6379,  name: 'redis-server',pid: 612  },
  { port: 8080,  name: 'docker',      pid: 1893 },
  { port: 8088,  name: 'nginx',       pid: 902  },
  { port: 9229,  name: 'node',        pid: 4421 },
  { port: 27017, name: 'mongod',      pid: 765  },
  { port: 4000,  name: 'python3',     pid: 3104 },
  { port: 7000,  name: 'ControlCenter',pid: 665 },
  { port: 4500,  name: 'rapportd',    pid: 412  },
  { port: 50000, name: 'python3',     pid: 5821 },
];

// Hotkey apps shown in the desktop / dock animation.
export type HotkeyApp = { key: string; name: string; grad: string; letter: string; tag: string };
export const hotkeyApps: HotkeyApp[] = [
  { key: 'F1', name: 'Dockerman',  grad: 'linear-gradient(135deg, #0db7ed, #066da5)', letter: 'D', tag: 'Docker Desktop Manager' },
  { key: 'F2', name: 'ServerBee',  grad: 'linear-gradient(135deg, #ffb900, #ff7a00)', letter: 'S', tag: 'Server Monitor' },
  { key: 'F3', name: 'Finder',     grad: 'linear-gradient(135deg, #6dd4ff, #1f8fff)', letter: 'F', tag: 'macOS File Browser' },
  { key: 'F4', name: 'Safari',     grad: 'linear-gradient(135deg, #36d4ff, #1873e8)', letter: 'S', tag: 'macOS Web Browser' },
  { key: 'F5', name: 'Notes',      grad: 'linear-gradient(135deg, #ffe28a, #f5b800)', letter: 'N', tag: 'macOS Notes' },
  { key: 'F6', name: 'Calculator', grad: 'linear-gradient(135deg, #2a2a2e, #0a0a0d)', letter: 'C', tag: 'macOS Calculator' },
];

// Toggle hero cards.
export type ToggleCard = {
  key: string;
  icon: string;
  iconOnBg: string;
  iconOnColor: string;
  cardClass?: string;
  name: Bi;
  desc: Bi;
  stateOn: Bi;
  stateOff: Bi;
};
export const toggleCards: ToggleCard[] = [
  { key: 'dark',        icon: 'moon',    iconOnBg: 'rgba(94,155,255,.18)',  iconOnColor: '#5e9bff',
    cardClass: 'dark-card',
    name: { zh: '深色模式', en: 'Dark Mode' },
    desc: { zh: '通过 AppleScript 翻转系统外观。', en: 'Flip system appearance via AppleScript.' },
    stateOn: { zh: '已启用', en: 'Engaged' }, stateOff: { zh: '已关闭', en: 'Disabled' } },
  { key: 'keepAwake',   icon: 'coffee',  iconOnBg: 'rgba(255,159,10,.18)',  iconOnColor: '#ff9f0a',
    cardClass: 'awake-card',
    name: { zh: 'Keep Awake', en: 'Keep Awake' },
    desc: { zh: '持有 IOPMAssertion，阻止显示器和系统休眠。', en: 'Holds an IOPMAssertion to prevent sleep.' },
    stateOn: { zh: '屏幕不会睡眠', en: 'Display stays on' }, stateOff: { zh: '按系统设置睡眠', en: 'Default sleep' } },
  { key: 'mute',        icon: 'mute',    iconOnBg: 'rgba(255,159,10,.18)',  iconOnColor: '#ff9f0a',
    name: { zh: '静音', en: 'Mute' },
    desc: { zh: '静音/取消静音 Core Audio 默认输出设备。', en: 'Mute the default Core Audio output device.' },
    stateOn: { zh: '输出已静音', en: 'Output muted' }, stateOff: { zh: '输出已开启', en: 'Output live' } },
  { key: 'hideDock',    icon: 'dock',    iconOnBg: 'rgba(94,155,255,.18)',  iconOnColor: '#5e9bff',
    name: { zh: '隐藏 Dock', en: 'Hide Dock' },
    desc: { zh: '切换 Dock 自动隐藏。', en: 'Toggle Dock auto-hide.' },
    stateOn: { zh: 'Dock 已隐藏', en: 'Dock hidden' }, stateOff: { zh: 'Dock 已显示', en: 'Dock visible' } },
  { key: 'hideMenubar', icon: 'menubar', iconOnBg: 'rgba(94,155,255,.18)',  iconOnColor: '#5e9bff',
    name: { zh: '自动隐藏菜单栏', en: 'Auto-hide MB' },
    desc: { zh: '切换 _HIHideMenuBar。', en: 'Toggle _HIHideMenuBar.' },
    stateOn: { zh: '菜单栏已隐藏', en: 'Menu bar hidden' }, stateOff: { zh: '菜单栏常驻', en: 'Menu bar visible' } },
  { key: 'showHidden',  icon: 'eye',     iconOnBg: 'rgba(48,209,88,.18)',   iconOnColor: '#30d158',
    name: { zh: '显示隐藏文件', en: 'Show Hidden' },
    desc: { zh: '切换 Finder 的 AppleShowAllFiles。', en: "Toggle Finder's AppleShowAllFiles." },
    stateOn: { zh: '隐藏文件可见', en: 'Hidden files shown' }, stateOff: { zh: '隐藏文件不可见', en: 'Hidden files hidden' } },
];

// Settings panel rows.
export type SettingsRow = {
  key: string;
  icon: string;
  type: 'submenu' | 'toggle' | 'action';
  label: Bi;
};
export const settingsRows: SettingsRow[] = [
  { key: 'shortcuts', icon: 'keyboard', type: 'submenu', label: { zh: '应用快捷键', en: 'App Shortcuts' } },
  { key: 'ports',     icon: 'globe',    type: 'submenu', label: { zh: '端口管理', en: 'Port Manager' } },
  { key: 'keepAwake', icon: 'coffee',   type: 'toggle',  label: { zh: 'Keep Awake', en: 'Keep Awake' } },
  { key: 'mute',      icon: 'mute',     type: 'toggle',  label: { zh: '静音', en: 'Mute' } },
  { key: 'hideDesk',  icon: 'hideDesk', type: 'toggle',  label: { zh: '隐藏桌面图标', en: 'Hide Desktop' } },
  { key: 'showHidden',icon: 'eye',      type: 'toggle',  label: { zh: '显示隐藏文件', en: 'Show Hidden Files' } },
  { key: 'dark',      icon: 'moon',     type: 'toggle',  label: { zh: '深色模式', en: 'Dark Mode' } },
  { key: 'lock',      icon: 'lock',     type: 'action',  label: { zh: '锁定屏幕', en: 'Lock Screen' } },
  { key: 'trash',     icon: 'trash',    type: 'action',  label: { zh: '清空废纸篓', en: 'Empty Trash' } },
];

// Hyper Key tab — letter triggers mixing apps and system actions.
export type HyperBinding =
  | {
      kind: 'app';
      letter: string;
      name: string;
      grad: string;
      tag: string;
    }
  | {
      kind: 'action';
      letter: string;
      name: Bi;
      stateOn: Bi;
      icon: string;
    };

export const hyperBindings: HyperBinding[] = [
  {
    kind: 'app',
    letter: 'S',
    name: 'Safari',
    grad: 'linear-gradient(135deg, #36d4ff, #1873e8)',
    tag: 'macOS Web Browser',
  },
  {
    kind: 'app',
    letter: 'F',
    name: 'Finder',
    grad: 'linear-gradient(135deg, #6dd4ff, #1f8fff)',
    tag: 'macOS File Browser',
  },
  {
    kind: 'action',
    letter: 'L',
    name: { zh: '锁定屏幕', en: 'Lock Screen' },
    stateOn: { zh: '已锁定', en: 'Locked' },
    icon: 'lock',
  },
  {
    kind: 'action',
    letter: 'M',
    name: { zh: '静音', en: 'Mute' },
    stateOn: { zh: '已静音', en: 'Muted' },
    icon: 'mute',
  },
];
