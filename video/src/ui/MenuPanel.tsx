import type {FC} from 'react';
import {staticFile} from 'remotion';
import type {Lang} from '../copy';
import {theme} from '../theme';

type MenuPanelProps = {
  lang: Lang;
};

type PanelRow = {
  zh: string;
  en: string;
  keys: string[];
  // Asset stem under public/icons (rendered from the real BuiltinItem SF Symbols
  // by scripts/render-symbols.swift; dots in the symbol name become underscores).
  symbol: string;
};

const panelRows: PanelRow[] = [
  {zh: '应用快捷键', en: 'App Shortcuts', keys: ['Hyper Key'], symbol: 'keyboard'},
  {zh: '端口管理', en: 'Port Manager', keys: ['⌘', 'P'], symbol: 'network'},
  {zh: '防止休眠', en: 'Keep Awake', keys: ['⌥', 'A'], symbol: 'cup_and_saucer_fill'},
  {zh: '静音', en: 'Mute', keys: ['⌥', 'M'], symbol: 'speaker_slash_fill'},
  {zh: '隐藏桌面图标', en: 'Hide Desktop', keys: ['⌥', 'H'], symbol: 'rectangle_on_rectangle_slash'},
  {zh: '显示隐藏文件', en: 'Show Hidden Files', keys: ['⌥', '.'], symbol: 'eye_fill'},
  {zh: '深色模式', en: 'Dark Mode', keys: ['⌥', 'D'], symbol: 'moon_fill'},
  {zh: '锁定屏幕', en: 'Lock Screen', keys: ['⌃', '⌘', 'Q'], symbol: 'lock_fill'},
  {zh: '清空废纸篓', en: 'Empty Trash', keys: ['⌘', '⌫'], symbol: 'trash_fill'},
  {zh: '截图到剪贴板', en: 'Screenshot to Clipboard', keys: ['⌘', '⇧', '5'], symbol: 'camera_viewfinder'},
  {zh: '剪贴板历史', en: 'Clipboard History', keys: [], symbol: 'doc_on_clipboard'},
  {zh: '显示器睡眠', en: 'Display Sleep', keys: ['⌥', 'S'], symbol: 'moon_zzz_fill'},
  {zh: '系统休眠', en: 'System Sleep', keys: ['⌃', '⌥', 'S'], symbol: 'powersleep'},
  {zh: '隐藏 Dock', en: 'Hide Dock', keys: ['⌥', 'K'], symbol: 'dock_rectangle'},
  {zh: '自动隐藏菜单栏', en: 'Auto-hide Menu Bar', keys: ['⌥', 'B'], symbol: 'menubar_rectangle'},
  {zh: '重启访达', en: 'Restart Finder', keys: ['⌥', 'F'], symbol: 'macwindow_on_rectangle'},
  {zh: '重启 Dock', en: 'Restart Dock', keys: ['⌥', 'R'], symbol: 'dock_arrow_down_rectangle'},
  {zh: '重启菜单栏', en: 'Restart Menu Bar', keys: ['⌥', 'N'], symbol: 'menubar_arrow_up_rectangle'},
  {zh: '刷新 DNS', en: 'Flush DNS', keys: ['⌥', 'G'], symbol: 'network'},
  {zh: '禁用键盘', en: 'Keyboard Lock', keys: ['⌥', 'L'], symbol: 'keyboard_fill'},
  {zh: '屏幕取词', en: 'Screen OCR', keys: ['⌥', 'O'], symbol: 'text_viewfinder'},
  {zh: '屏幕取色', en: 'Pick Color', keys: ['⌥', 'C'], symbol: 'eyedropper'},
  {zh: '识别二维码', en: 'Scan QR Code', keys: ['⌥', 'Q'], symbol: 'qrcode_viewfinder'},
  {zh: '显示器亮度', en: 'Display Brightness', keys: ['⌥', '↑'], symbol: 'sun_max'},
  {zh: '窗口布局', en: 'Window Layout', keys: ['⌥', 'W'], symbol: 'macwindow'},
  {zh: 'Hosts 管理', en: 'Hosts Manager', keys: ['⌥', 'T'], symbol: 'list_bullet_rectangle'},
];

export const MenuPanel: FC<MenuPanelProps> = ({lang}) => (
  <div
    data-ui="menu-panel"
    style={{
      position: 'absolute',
      top: 150,
      left: '50%',
      width: 420,
      maxHeight: 720,
      padding: 10,
      borderRadius: 16,
      border: `.5px solid ${theme.colors.lineStrong}`,
      background: theme.gradients.panel,
      color: theme.colors.text,
      fontFamily: theme.fonts.sans,
      boxShadow: theme.shadow.panel,
      overflow: 'hidden',
      transform: 'translateX(-50%)',
      maskImage: 'linear-gradient(180deg, #000 82%, transparent 100%)',
      WebkitMaskImage: 'linear-gradient(180deg, #000 82%, transparent 100%)',
    }}
  >
    <div
      style={{
        height: 46,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '0 10px 0 12px',
        borderBottom: `1px solid ${theme.colors.line}`,
        marginBottom: 8,
      }}
    >
      <span style={{fontSize: 18, fontWeight: 900}}>AnyDoor</span>
      <span
        style={{
          fontSize: 13,
          color: theme.colors.textDim,
          fontFamily: theme.fonts.mono,
          fontWeight: 800,
        }}
      >
        {lang === 'zh' ? '26 个已启用' : '26 enabled'}
      </span>
    </div>

    <div style={{display: 'flex', flexDirection: 'column', gap: 2}}>
      {panelRows.map((row, index) => {
        const isCaptureRow = row.en === 'Screenshot to Clipboard' || row.en === 'Clipboard History';
        return (
          <div
            key={`${row.en}-${index}`}
            style={{
              height: 42,
              display: 'grid',
              gridTemplateColumns: '32px minmax(0, 1fr) auto',
              alignItems: 'center',
              gap: 9,
              padding: '0 8px',
              borderRadius: 10,
              background: isCaptureRow
                ? 'linear-gradient(90deg, rgba(94,155,255,.22), rgba(191,90,242,.14))'
                : index < 2
                  ? 'rgba(255,255,255,.075)'
                  : 'transparent',
              boxShadow: isCaptureRow ? '0 0 0 1px rgba(94,155,255,.24) inset' : 'none',
            }}
          >
            <span
              style={{
                width: 26,
                height: 26,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                borderRadius: 8,
                // Neutral gray badge (matches the real app's PanelRowView): the
                // icon is a plain white glyph, not a colored chip.
                background: 'rgba(255,255,255,.1)',
                boxShadow: '0 0 0 .5px rgba(255,255,255,.08) inset',
              }}
            >
              {/* Plain <img> (not Remotion <Img>) keeps MenuPanel renderable via
                  bare renderToStaticMarkup in the system-montage test; the icons are
                  tiny local PNGs that decode well before the panel fades in. */}
              <img
                src={staticFile(`icons/${row.symbol}.png`)}
                alt=""
                style={{width: 16, height: 16, objectFit: 'contain'}}
              />
            </span>
            <span
              style={{
                minWidth: 0,
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
                fontSize: 15,
                fontWeight: 700,
              }}
            >
              {lang === 'zh' ? row.zh : row.en}
            </span>
            <span style={{display: 'flex', justifyContent: 'flex-end', gap: 4}}>
              {row.keys.map((key, keyIndex) => (
                <span
                  key={`${row.en}-${key}-${keyIndex}`}
                  style={{
                    minWidth: key === 'Hyper Key' ? 76 : key === 'Space' ? 48 : 24,
                    height: 24,
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'center',
                    padding: '0 6px',
                    borderRadius: 7,
                    border: `.5px solid ${theme.colors.lineStrong}`,
                    background: isCaptureRow ? 'rgba(255,255,255,.16)' : 'rgba(255,255,255,.10)',
                    color: theme.colors.textDim,
                    fontFamily: theme.fonts.mono,
                    fontSize: 12,
                    fontWeight: 900,
                    lineHeight: 1,
                  }}
                >
                  {key}
                </span>
              ))}
            </span>
          </div>
        );
      })}
    </div>
  </div>
);
