// Copy and demo data for the interactive hotkey unit in the hero. Imported by
// both HotkeyUnit.astro's markup and its client script.
import type { Bi } from '../i18n';

export const unit = {
  name: { zh: '热键单元', en: 'Hotkey unit' },
  modeAria: { zh: '演示模式', en: 'Demo mode' },
  modeFkeys: { zh: 'F 键模式', en: 'F-keys' },
  modeHyper: { zh: 'Hyper Key', en: 'Hyper Key' },
  kbAria: { zh: '可交互的热键键盘', en: 'Interactive hotkey keyboard' },
  demoA: { zh: '按一下打开，', en: 'Press to open. ' },
  demoB: { zh: '再按一下隐藏。', en: 'Press again to hide.' },
  hintF: { zh: '试试', en: 'Try' },
  hintEsc: { zh: '，或', en: ', or' },
  hintH: { zh: '按住', en: 'Hold' },
  actionTag: { zh: '系统动作', en: 'System action' },
  toggleTag: { zh: '系统开关', en: 'System toggle' },
};

// LCD readout strings; the client script renders them in the active language.
export const lcd = {
  ready: { zh: '就绪', en: 'READY' },
  tryF: { zh: '试试按 F1–F6，也可以按 Esc 全部关闭。', en: 'Try F1–F6, or hit Esc to dismiss.' },
  tryH: { zh: '按住 ⇪ 再按字母键，Hyper 把单键变成一整层快捷键。', en: 'Hold ⇪ then a letter. Hyper turns one key into a whole shortcut layer.' },
  selfTest: { zh: '自检中', en: 'SELF-TEST' },
  selfTestSub: { zh: 'F1–F6 绑定正常。', en: 'F1–F6 bindings OK.' },
  opened: { zh: '已打开 · 置于最前', en: 'Opened · frontmost' },
  raised: { zh: '已切到最前', en: 'Brought to front' },
  hidden: { zh: '已隐藏，再按一次即可唤回', en: 'Hidden. Press again to bring it back.' },
  escAll: { zh: '全部关闭', en: 'All dismissed' },
  escNone: { zh: '当前没有打开的 App', en: 'Nothing open' },
  armed: { zh: 'Hyper 已就绪', en: 'Hyper armed' },
  locked: { zh: '屏幕已锁定', en: 'Locked' },
  muted: { zh: '输出已静音', en: 'Muted' },
  unmuted: { zh: '输出已开启', en: 'Unmuted' },
  lock: { zh: '锁定屏幕', en: 'Lock Screen' },
  mute: { zh: '静音', en: 'Mute' },
} satisfies Record<string, Bi>;

export interface DemoApp {
  key: string;
  name: string;
  letter: string;
  tag: string;
}

// F1–F6 bindings in F-keys mode.
export const APPS: DemoApp[] = [
  { key: 'F1', name: 'Dockerman', letter: 'D', tag: 'Docker Desktop Manager' },
  { key: 'F2', name: 'ServerBee', letter: 'S', tag: 'Server Monitor' },
  { key: 'F3', name: 'Finder', letter: 'F', tag: 'macOS File Browser' },
  { key: 'F4', name: 'Safari', letter: 'S', tag: 'macOS Web Browser' },
  { key: 'F5', name: 'Notes', letter: 'N', tag: 'macOS Notes' },
  { key: 'F6', name: 'Calculator', letter: 'C', tag: 'macOS Calculator' },
];

export type HyperBinding =
  | { key: string; l: string; kind: 'app'; name: string; tag: string }
  | { key: string; l: string; kind: 'lock' | 'mute' };

// ⇪ + letter bindings in Hyper Key mode.
export const HYPER: HyperBinding[] = [
  { key: 'KeyS', l: 'S', kind: 'app', name: 'Safari', tag: 'macOS Web Browser' },
  { key: 'KeyF', l: 'F', kind: 'app', name: 'Finder', tag: 'macOS File Browser' },
  { key: 'KeyL', l: 'L', kind: 'lock' },
  { key: 'KeyM', l: 'M', kind: 'mute' },
];

export function hyperName(h: HyperBinding): Bi {
  if (h.kind === 'app') return { zh: h.name, en: h.name };
  return h.kind === 'lock' ? lcd.lock : lcd.mute;
}

// One keycap. `id` is the KeyboardEvent.code it mirrors; `w` is its flex-grow.
export interface KeyDef {
  id: string;
  lg: string;
  w: number;
  kind: string;
  sub: string;
}
export type KeySlot = KeyDef | { stack: KeyDef[]; w: number };
export interface KeyRow {
  cls: string;
  keys: KeySlot[];
}

const K = (id: string, lg: string, w = 1, kind = '', sub = ''): KeyDef => ({ id, lg, w, kind, sub });
const letters = (s: string) => s.split('').map((c) => K('Key' + c, c));
const FN = ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10', 'F11', 'F12'];

// A US-layout MacBook keyboard.
export const ROWS: KeyRow[] = [
  { cls: 'fnrow', keys: [K('Escape', 'esc', 1.5, 'esc'), ...FN.map((f) => K(f, f, 1, 'fn')), K('Power', '⏻', 1.5, 'fn')] },
  { cls: '', keys: [K('Backquote', '`'), ...'1234567890'.split('').map((c) => K('Digit' + c, c)), K('Minus', '-'), K('Equal', '='), K('Backspace', '⌫', 2, 'm', 'delete')] },
  { cls: '', keys: [K('Tab', '⇥', 1.5, 'm', 'tab'), ...letters('QWERTYUIOP'), K('BracketLeft', '['), K('BracketRight', ']'), K('Backslash', '\\', 1.5, 'm')] },
  { cls: '', keys: [K('CapsLock', '⇪', 1.8, 'hyper', 'hyper'), ...letters('ASDFGHJKL'), K('Semicolon', ';'), K('Quote', "'"), K('Enter', '↩', 2.2, 'm', 'return')] },
  { cls: '', keys: [K('ShiftLeft', '⇧', 2.3, 'm', 'shift'), ...letters('ZXCVBNM'), K('Comma', ','), K('Period', '.'), K('Slash', '/'), K('ShiftRight', '⇧', 2.7, 'm', 'shift')] },
  {
    cls: '',
    keys: [
      K('Fn', 'fn', 1, 'm'), K('ControlLeft', '⌃', 1, 'm', 'control'), K('AltLeft', '⌥', 1, 'm', 'option'), K('MetaLeft', '⌘', 1.25, 'm', 'command'),
      K('Space', '', 5.5),
      K('MetaRight', '⌘', 1.25, 'm', 'command'), K('AltRight', '⌥', 1, 'm', 'option'),
      K('ArrowLeft', '←', 1, 'm half'), { stack: [K('ArrowUp', '↑', 1, 'm'), K('ArrowDown', '↓', 1, 'm')], w: 1 }, K('ArrowRight', '→', 1, 'm half'),
    ],
  },
];

// Every code drawn on the keyboard; other keys are ignored.
export const CODES = new Set(ROWS.flatMap((r) => r.keys.flatMap((k) => ('stack' in k ? k.stack.map((s) => s.id) : [k.id]))));

// Older browsers report the Command keys as OS*.
export const ALIAS: Record<string, string> = { OSLeft: 'MetaLeft', OSRight: 'MetaRight' };

export const isAppKey = (id: string) => /^F[1-6]$/.test(id);
