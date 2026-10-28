// Copy and demo data for the feature workbench (§ 02, modules M-01 – M-08).
// Workbench.astro renders it server-side; its client script imports the same
// tables to re-render the interactive modules.
import type { Bi, Lang } from '../i18n';

export const board = {
  eyebrow: { zh: '不止于此', en: 'More in the box' },
  h2a: { zh: '一个菜单栏，', en: 'One menu bar,' },
  h2b: { zh: '一整套工具箱。', en: 'a whole toolbox.' },
  lede: {
    zh: '系统开关、端口、内置动作、剪贴板历史、外接显示器亮度、窗口布局、Hosts、命令面板。每一块都收进同一个面板、同一套热键。下面的模块都可以直接按。',
    en: 'System toggles, ports, built-in actions, clipboard history, external-display brightness, window layout, hosts, a command palette. Each one folds into the same panel and the same hotkeys. Every module below is live; press it.',
  },

  togName: { zh: '系统开关', en: 'System toggles' },
  togH: { zh: '一键翻转每一个你常翻的设置。', en: 'Flip every setting you keep flipping.' },
  togLede: {
    zh: '深色模式、静音、Keep Awake、隐藏 Dock、自动隐藏菜单栏……全部映射成一个开关，或一颗键。',
    en: 'Dark mode, mute, Keep Awake, hide Dock, auto-hide menu bar: each mapped to a single toggle, or a single key.',
  },
  togOn: { zh: '开', en: 'on' },

  portName: { zh: '端口管理', en: 'Port manager' },
  live: { zh: '实时', en: 'Live' },
  portH: { zh: '哪个进程占了 :3000？', en: 'What’s running on :3000?' },
  portLede: {
    zh: '列出系统上每个正在监听的端口。按端口号或进程名搜索，平铺或按进程分组，扫描失败自动重试。',
    en: 'Every listening port on the system. Search by port or process, flat or grouped by process, with live refresh and retry on scan failure.',
  },
  ph: { zh: '搜索端口或进程…', en: 'Search ports or processes…' },
  viewAria: { zh: '视图', en: 'View' },
  flat: { zh: '平铺', en: 'Flat' },
  tree: { zh: '树状', en: 'Tree' },
  noMatch: { zh: '无匹配端口', en: 'No matching ports' },
  ports: { zh: ' 个端口', en: ' ports' },

  actName: { zh: '内置动作', en: 'Built-in actions' },
  toClip: { zh: '→ 剪贴板', en: '→ clipboard' },
  actH: { zh: 'OCR、取色、截图，都在一个键之内。', en: 'OCR, color picker, capture: one key away.' },
  actLede: {
    zh: '绑定任意热键来运行 macOS 自带的内置动作，结果直接进入剪贴板。',
    en: 'Bind any hotkey to a built-in macOS action. Results land directly on the clipboard.',
  },
  copied: { zh: '已复制到剪贴板', en: 'Copied to clipboard' },
  idleOut: { zh: '按下任意一颗键', en: 'Press any of the three keys' },

  clipName: { zh: '剪贴板历史', en: 'Clipboard' },
  clipH: { zh: '剪贴板历史墙', en: 'Clipboard Wall' },
  clipDesc: {
    zh: '持久化的剪贴板历史：文本、图片、文件，外加截图、取色、OCR、二维码的结果，按类别分页、可搜索、可收藏。',
    en: 'A persistent clipboard history: text, images, files, plus screenshot, color, OCR and QR results. Paged by category, searchable, with favorites.',
  },

  briH: { zh: '外接显示器亮度', en: 'Display brightness' },
  briDesc: {
    zh: '经 DDC/CI 调节，带原生 OSD。热键调节鼠标所在的那块屏。',
    en: 'Over DDC/CI with the native OSD. Hotkeys nudge the display under your cursor.',
  },

  layName: { zh: '窗口布局', en: 'Window layout' },
  layTag: { zh: '17 个动作', en: '17 actions' },
  layDesc: {
    zh: '把前台窗口贴到半屏、四分之一屏、居中或铺满，每个布局动作都能绑定一个热键。',
    en: 'Snap the focused window to halves, quarters, center, or fill. Every layout action is its own bindable hotkey.',
  },

  hostName: { zh: 'Hosts 管理', en: 'Hosts manager' },
  hostTag: { zh: '特权 helper', en: 'XPC helper' },
  hostDesc: {
    zh: '在菜单栏里编辑 /etc/hosts，启用或停用 profile。写入由特权 XPC helper 完成，并校验调用方代码签名。',
    en: 'Edit /etc/hosts and flip host profiles from the menu bar. Writes go through a privileged XPC helper that verifies the caller’s code signature.',
  },

  palName: { zh: '命令面板', en: 'Command palette' },
  palTag: { zh: '搜索 · 计算 · 换算', en: 'Search · calc · convert' },
  palDesc: {
    zh: '热键唤起的搜索框：启动 App、跳转端口、跑内置动作，内置科学计算器、单位 / 时区 / 汇率换算，以及 base64 / URL / 哈希 / JSON 等开发者工具。',
    en: 'A hotkey-summoned search box: launch apps, jump to ports, run built-in actions, with a scientific calculator, unit / time-zone / currency conversion, and dev tools (base64 / URL / hash / JSON).',
  },
  palCalc: { zh: '计算', en: 'calc' },
  palConv: { zh: '换算', en: 'convert' },
  palPort: { zh: '端口', en: 'port' },
} satisfies Record<string, Bi>;

// M-01 ─ system toggles. Dark Mode and Hide Dock start on.
export type BoardToggle = { key: string; name: Bi; desc: Bi; on: Bi; off: Bi; initial: boolean };
export const boardToggles: BoardToggle[] = [
  { key: 'dark', name: { zh: '深色模式', en: 'Dark Mode' }, desc: { zh: '经 AppleScript 翻转系统外观', en: 'Flips appearance via AppleScript' }, on: { zh: '已启用', en: 'Engaged' }, off: { zh: '已关闭', en: 'Disabled' }, initial: true },
  { key: 'keepAwake', name: { zh: 'Keep Awake', en: 'Keep Awake' }, desc: { zh: '持有 IOPMAssertion 阻止休眠', en: 'Holds an IOPMAssertion' }, on: { zh: '屏幕不会睡眠', en: 'Display stays on' }, off: { zh: '按系统设置睡眠', en: 'Default sleep' }, initial: false },
  { key: 'mute', name: { zh: '静音', en: 'Mute' }, desc: { zh: 'Core Audio 默认输出设备', en: 'Default Core Audio output' }, on: { zh: '输出已静音', en: 'Output muted' }, off: { zh: '输出已开启', en: 'Output live' }, initial: false },
  { key: 'hideDock', name: { zh: '隐藏 Dock', en: 'Hide Dock' }, desc: { zh: '切换 Dock 自动隐藏', en: 'Toggles Dock auto-hide' }, on: { zh: 'Dock 已隐藏', en: 'Dock hidden' }, off: { zh: 'Dock 已显示', en: 'Dock visible' }, initial: true },
  { key: 'hideMenubar', name: { zh: '自动隐藏菜单栏', en: 'Auto-hide Menu Bar' }, desc: { zh: '切换 _HIHideMenuBar', en: 'Toggles _HIHideMenuBar' }, on: { zh: '菜单栏已隐藏', en: 'Menu bar hidden' }, off: { zh: '菜单栏常驻', en: 'Menu bar visible' }, initial: false },
  { key: 'showHidden', name: { zh: '显示隐藏文件', en: 'Show Hidden Files' }, desc: { zh: 'Finder 的 AppleShowAllFiles', en: 'Finder’s AppleShowAllFiles' }, on: { zh: '隐藏文件可见', en: 'Hidden files shown' }, off: { zh: '隐藏文件不可见', en: 'Hidden files hidden' }, initial: false },
];

// M-02 ─ sample listening ports: generic services, no real app names.
export type BoardPort = { port: number; name: string; pid: number };
export const boardPorts: BoardPort[] = [
  { port: 3000, name: 'node', pid: 1024 },
  { port: 5173, name: 'vite', pid: 2156 },
  { port: 5432, name: 'postgres', pid: 487 },
  { port: 6379, name: 'redis-server', pid: 612 },
  { port: 8080, name: 'docker', pid: 1893 },
  { port: 8088, name: 'nginx', pid: 902 },
  { port: 9229, name: 'node', pid: 4421 },
  { port: 27017, name: 'mongod', pid: 765 },
  { port: 4000, name: 'python3', pid: 3104 },
  { port: 7000, name: 'ControlCenter', pid: 665 },
  { port: 4500, name: 'rapportd', pid: 412 },
  { port: 50000, name: 'python3', pid: 5821 },
];

export type PortRow = { a: string; b: string; c: string; cls: string };

// Rows for the port list. An empty query highlights :3000 (the headline's
// question); otherwise an exact port match is highlighted.
export function portRows(query: string, view: 'flat' | 'tree', lang: Lang): { rows: PortRow[]; matches: number } {
  const q = query.trim().toLowerCase().replace(/^:/, '');
  const match = boardPorts.filter((p) => !q || String(p.port).includes(q) || p.name.toLowerCase().includes(q));
  const hit = (p: BoardPort) => ((q ? String(p.port) === q : p.port === 3000) ? 'hit' : '');
  const rows: PortRow[] = [];
  if (view === 'flat') {
    match
      .slice()
      .sort((a, b) => a.port - b.port)
      .forEach((p) => rows.push({ a: ':' + p.port, b: p.name, c: 'PID ' + p.pid, cls: hit(p) }));
  } else {
    const groups = new Map<string, BoardPort[]>();
    match.forEach((p) => groups.set(p.name, [...(groups.get(p.name) ?? []), p]));
    [...groups.keys()].sort().forEach((name) => {
      const ports = groups.get(name) ?? [];
      const n = ports.length;
      rows.push({ a: name, b: '', c: lang === 'en' ? `${n} port${n > 1 ? 's' : ''}` : `${n} 个`, cls: 'grp' });
      ports.forEach((p) => rows.push({ a: ':' + p.port, b: '', c: 'PID ' + p.pid, cls: ('child ' + hit(p)).trim() }));
    });
  }
  return { rows, matches: match.length };
}

// M-03 ─ built-in actions and what each one leaves on the clipboard.
export type BoardActionKey = 'ocr' | 'color' | 'shot';
export const boardActions: { key: BoardActionKey; glyph: string; name: Bi; desc: Bi; out: string }[] = [
  { key: 'ocr', glyph: 'OCR', name: { zh: '屏幕取词', en: 'Screen OCR' }, desc: { zh: 'Vision 识别区域文字。', en: 'Vision reads text in a region.' }, out: '“One key. Any door.”' },
  { key: 'color', glyph: 'HEX', name: { zh: '屏幕取色', en: 'Pick Color' }, desc: { zh: '任意像素的 HEX。', en: 'Any pixel, as HEX.' }, out: '#2253B5' },
  { key: 'shot', glyph: '⬚', name: { zh: '区域截图', en: 'Region Screenshot' }, desc: { zh: '交互式框选。', en: 'Interactive region capture.' }, out: 'PNG · 1280×800' },
];

// M-04 ─ clipboard wall categories and sample entries (the first three that
// match the selected category are shown).
export type ClipCategory = 'all' | 'text' | 'image' | 'file' | 'color' | 'fav';
export const clipCategories: { key: ClipCategory; label: Bi }[] = [
  { key: 'all', label: { zh: '全部', en: 'All' } },
  { key: 'text', label: { zh: '文本', en: 'Text' } },
  { key: 'image', label: { zh: '图片', en: 'Images' } },
  { key: 'file', label: { zh: '文件', en: 'Files' } },
  { key: 'color', label: { zh: '取色', en: 'Colors' } },
  { key: 'fav', label: { zh: '收藏', en: 'Favorites' } },
];
export const clipEntries: { cat: Exclude<ClipCategory, 'all' | 'fav'>; ty: Bi; v: string; fav?: boolean; img?: boolean; col?: boolean }[] = [
  { cat: 'text', ty: { zh: '文本', en: 'text' }, v: 'make swift-release', fav: true },
  { cat: 'color', ty: { zh: '取色', en: 'color' }, v: '#2253B5', col: true },
  { cat: 'image', ty: { zh: '图片', en: 'image' }, v: 'Screenshot.png', img: true },
  { cat: 'file', ty: { zh: '文件', en: 'file' }, v: 'AnyDoor.dmg' },
  { cat: 'text', ty: { zh: 'OCR', en: 'OCR' }, v: 'One key. Any door.', fav: true },
];
export const CLIP_VISIBLE = 3;

// M-05 ─ starting brightness (percent).
export const BRIGHTNESS_INITIAL = 65;

// M-06 ─ a representative slice of the 17 window layout actions. Rectangles
// are fractions of the visible frame.
export type BoardLayout = { key: string; label: Bi; x: number; y: number; w: number; h: number };
export const boardLayouts: BoardLayout[] = [
  { key: 'left', label: { zh: '左半', en: 'Left' }, x: 0, y: 0, w: 0.5, h: 1 },
  { key: 'right', label: { zh: '右半', en: 'Right' }, x: 0.5, y: 0, w: 0.5, h: 1 },
  { key: 'tl', label: { zh: '左上', en: 'Top-left' }, x: 0, y: 0, w: 0.5, h: 0.5 },
  { key: 'center', label: { zh: '居中', en: 'Center' }, x: 0.2, y: 0.15, w: 0.6, h: 0.7 },
  { key: 'fill', label: { zh: '铺满', en: 'Fill' }, x: 0, y: 0, w: 1, h: 1 },
];

// M-07 ─ the stock macOS /etc/hosts body, below its comment line.
export const hostsBody = '127.0.0.1    localhost\n255.255.255.255  broadcasthost\n::1          localhost';
