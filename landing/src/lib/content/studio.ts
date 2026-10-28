// Copy and demo data for the capture suite (§ 03) and the settings window (§ 04).
import type { Bi } from '../i18n';

export const capture = {
  eyebrow: { zh: '截图套件', en: 'Capture suite' },
  h2a: { zh: '框选、滚动、录制，', en: 'Select, scroll, record:' },
  h2b: { zh: '一个工具栏全包。', en: 'one toolbar does it all.' },
  lede: {
    zh: '一个热键冻结屏幕，弹出可拖拽的选区与贴附工具栏：区域、窗口、全屏、滚动长截图、屏幕录制，随手切换。截图落地，浮层就在选区旁。',
    en: 'One hotkey freezes the screen and brings up a draggable selection with an attached toolbar: region, window, fullscreen, scrolling long-shot and screen recording, switched on the fly. The instant a shot lands, a quick-access overlay sits beside it.',
  },
  toolbarName: { zh: '选区工具栏', en: 'Selection toolbar' },
  badge: { zh: '冻屏选区', en: 'Frozen selection' },
  phLabel: { zh: '桌面截图占位', en: 'desktop screenshot' },
  scrollTitle: { zh: '交互式滚动截图', en: 'Interactive scrolling' },
  scrollDesc: {
    zh: '你自己滚动目标，AnyDoor 实时抓帧、重叠对齐、像素级拼接，预览随之增长。',
    en: 'You scroll the target; AnyDoor grabs frames live, overlap-aligned and pixel-exact, as the preview grows.',
  },
  frames: { zh: '帧已捕获', en: 'frames captured' },
  scrollStep: { zh: '向下滚动', en: 'Scroll down' },
  scrollCancel: { zh: '取消', en: 'Cancel' },
  overlayTitle: { zh: '快捷操作浮层', en: 'Quick-access overlay' },
  overlayDesc: {
    zh: '复制、保存、编辑、钉在屏幕上、OCR、重拍、删除，截图落地即触手可及。',
    en: 'Copy, save, edit, pin on screen, OCR, re-capture, delete: within reach the instant a shot lands.',
  },
  recTitle: { zh: '屏幕录制', en: 'Screen recording' },
  recDesc: {
    zh: '全屏或选区录制为 MOV / MP4 / GIF，可选光标、麦克风、摄像头浮层与按键显示。',
    en: 'Record full screen or a region to MOV / MP4 / GIF, with optional cursor, mic, webcam overlay, and keystroke display.',
  },
  recState: { zh: '录制中', en: 'Recording' },
  recIdle: { zh: '待机', en: 'Standby' },
  recStop: { zh: '停止', en: 'Stop' },
  recStart: { zh: '开始录制', en: 'Start recording' },
} satisfies Record<string, Bi>;

export type CaptureTool = 'region' | 'window' | 'full' | 'scroll' | 'record';

// Selection rectangles per tool, as fractions of the stage.
export const captureSelections: Record<CaptureTool, { x: number; y: number; w: number; h: number }> = {
  region: { x: 0.2, y: 0.24, w: 0.44, h: 0.4 },
  window: { x: 0.1, y: 0.13, w: 0.54, h: 0.64 },
  full: { x: 0, y: 0, w: 1, h: 1 },
  scroll: { x: 0.36, y: 0.06, w: 0.3, h: 0.74 },
  record: { x: 0.14, y: 0.18, w: 0.56, h: 0.52 },
};

// The stage stands in for a 1512 × 945 point display; the dims label reads in those units.
export const captureScreen = { w: 1512, h: 945 };

export const captureTools: { id: CaptureTool; glyph: string; label: Bi }[] = [
  { id: 'region', glyph: '⬚', label: { zh: '区域', en: 'Region' } },
  { id: 'window', glyph: '▢', label: { zh: '窗口', en: 'Window' } },
  { id: 'full', glyph: '⛶', label: { zh: '全屏', en: 'Fullscreen' } },
  { id: 'scroll', glyph: '⇵', label: { zh: '滚动', en: 'Scrolling' } },
  { id: 'record', glyph: '◉', label: { zh: '录制', en: 'Record' } },
];

// Quick-access overlay buttons: idle label, then the label shown briefly after a press.
export const captureOverlay: { id: string; label: Bi; done: Bi }[] = [
  { id: 'copy', label: { zh: '复制', en: 'Copy' }, done: { zh: '已复制', en: 'Copied' } },
  { id: 'save', label: { zh: '保存', en: 'Save' }, done: { zh: '已保存', en: 'Saved' } },
  { id: 'edit', label: { zh: '编辑', en: 'Edit' }, done: { zh: '编辑', en: 'Edit' } },
  { id: 'pin', label: { zh: '钉住', en: 'Pin' }, done: { zh: '已钉住', en: 'Pinned' } },
  { id: 'ocr', label: { zh: 'OCR', en: 'OCR' }, done: { zh: 'OCR', en: 'OCR' } },
];

export const captureInitial = { tool: 'region' as CaptureTool, frames: 6, recOn: true, recSec: 7 };

// Scrolling demo: each "Scroll down" press adds FRAME_STEP frames up to FRAME_MAX;
// the strip draws at most FRAME_SLOTS of them.
export const FRAME_STEP = 3;
export const FRAME_MAX = 48;
export const FRAME_SLOTS = 12;
// How long a quick-access button shows its "done" label.
export const OVERLAY_RESET_MS = 1400;

// Selection size in display points, e.g. "665 × 378".
export function captureDims(tool: CaptureTool): string {
  const s = captureSelections[tool];
  return `${Math.round(s.w * captureScreen.w)} × ${Math.round(s.h * captureScreen.h)}`;
}

// Recording clock, mm:ss.
export function formatClock(sec: number): string {
  return `${String(Math.floor(sec / 60)).padStart(2, '0')}:${String(sec % 60).padStart(2, '0')}`;
}

export const settings = {
  eyebrow: { zh: '设置面板', en: 'Settings' },
  h2a: { zh: '拖拽排序面板项，', en: 'Drag-to-reorder rows.' },
  h2b: { zh: '录入式快捷键。', en: 'Inline hotkey recorder.' },
  lede: {
    zh: '「面板」标签页：拖拽重排、按项隐藏、内联录入热键、类型徽标（开关 / 动作 / 子菜单）。「通用」标签页：开机启动、菜单栏图标样式、权限状态。',
    en: 'In the Panel tab: drag-to-reorder, per-item visibility, inline hotkey recorder, type badges (toggle / action / submenu). In the General tab: launch at login, menu bar icon style, accessibility & automation permissions.',
  },
  tipDrag: { zh: '拖动手柄重排；聚焦手柄后也可以用 ↑ ↓。', en: 'Drag a handle to reorder, or focus it and use ↑ ↓.' },
  tipRec: { zh: '点「点击录入」再按下组合键，Esc 取消。', en: 'Click “Click to record”, then press a combination. Esc cancels.' },
  hint: {
    zh: '系统条目无法删除，只能隐藏；应用快捷键可自由增删。',
    en: 'System items can be hidden but not removed; app shortcuts can be added or removed freely.',
  },
  tabPanel: { zh: '面板', en: 'Panel' },
  tabGeneral: { zh: '通用', en: 'General' },
  record: { zh: '点击录入', en: 'Click to record' },
  recording: { zh: '请按键…', en: 'Press keys…' },
  handle: { zh: '拖动排序', en: 'Reorder' },
  show: { zh: '显示', en: 'Show' },
  hide: { zh: '隐藏', en: 'Hide' },
  hotkeyFor: { zh: '录入热键：', en: 'Record hotkey: ' },
  footL: { zh: '拖动以排序', en: 'Drag to reorder' },
  visible: { zh: ' 项可见', en: ' visible' },
  gLogin: { zh: '开机启动', en: 'Launch at login' },
  gIcon: { zh: '菜单栏图标样式', en: 'Menu bar icon style' },
  gAx: { zh: '辅助功能权限', en: 'Accessibility' },
  gAuto: { zh: '自动化权限', en: 'Automation' },
  granted: { zh: '已授权', en: 'Granted' },
  // Screen-reader announcements; {label}, {n}, {total} and {keys} are filled in by the script.
  moved: { zh: '{label} 已移到第 {n} 位，共 {total} 项', en: '{label} moved to position {n} of {total}' },
  recorded: { zh: '{label} 的热键已设为 {keys}', en: 'Hotkey for {label} set to {keys}' },
} satisfies Record<string, Bi>;

export type SettingsRowType = 'toggle' | 'action' | 'submenu';

export const settingsBadges: Record<SettingsRowType, Bi> = {
  toggle: { zh: '开关', en: 'toggle' },
  action: { zh: '动作', en: 'action' },
  submenu: { zh: '子菜单', en: 'submenu' },
};

const meta = {
  system: { zh: '系统', en: 'system' },
  submenu: { zh: '系统 · 子菜单', en: 'system · submenu' },
  action: { zh: '系统 · 动作', en: 'system · action' },
  twoBindings: { zh: '2 个绑定', en: '2 bindings' },
} satisfies Record<string, Bi>;

// Built-in panel items (BuiltinItem in Sources/PluginInterface) in their demo order.
export const settingsRows: { key: string; type: SettingsRowType; label: Bi; meta: Bi }[] = [
  { key: 'shortcuts', type: 'submenu', label: { zh: '应用快捷键', en: 'App Shortcuts' }, meta: meta.twoBindings },
  { key: 'ports', type: 'submenu', label: { zh: '端口管理', en: 'Port Manager' }, meta: meta.submenu },
  { key: 'keepAwake', type: 'toggle', label: { zh: 'Keep Awake', en: 'Keep Awake' }, meta: meta.system },
  { key: 'mute', type: 'toggle', label: { zh: '静音', en: 'Mute' }, meta: meta.system },
  { key: 'hideDesk', type: 'toggle', label: { zh: '隐藏桌面图标', en: 'Hide Desktop' }, meta: meta.system },
  { key: 'showHidden', type: 'toggle', label: { zh: '显示隐藏文件', en: 'Show Hidden Files' }, meta: meta.system },
  { key: 'dark', type: 'toggle', label: { zh: '深色模式', en: 'Dark Mode' }, meta: meta.system },
  { key: 'lock', type: 'action', label: { zh: '锁定屏幕', en: 'Lock Screen' }, meta: meta.action },
  { key: 'trash', type: 'action', label: { zh: '清空废纸篓', en: 'Empty Trash' }, meta: meta.action },
];

export const settingsInitial = {
  hidden: ['hideDesk'] as string[],
  keys: { dark: '⌃⌥D' } as Record<string, string>,
  login: true,
};
