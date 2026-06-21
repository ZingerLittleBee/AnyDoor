export type Lang = 'zh' | 'en';
export type Bi = Record<Lang, string>;

export const copy = {
  coldOpen: {
    caption: {zh: '一颗按键，一扇任意门', en: 'One key. Any door.'},
  },
  hotkey: {
    caption: {zh: '按一下打开，再按一下隐藏。', en: 'Press to open. Press again to hide.'},
  },
  palette: {
    caption: {zh: '命令面板 · 搜索、计算、换算一切。', en: 'Command palette — search, calc, convert.'},
    queryCalc: '1234 * 8%',
    resultCalc: '98.72',
    queryConvert: '100 USD to CNY',
    convertLabel: {zh: '汇率换算', en: 'Currency'},
    convertResult: '¥712.50',
  },
  ports: {
    caption: {zh: '哪个进程占了 :3000？一键结束。', en: "What's on :3000? End it with one key."},
    confirmTitle: {zh: '结束进程？', en: 'Kill process?'},
    confirmMessage: {
      zh: 'node（端口 :3000 · PID 1024）将被结束。',
      en: 'node (port :3000 · PID 1024) will be terminated.',
    },
    confirmButton: {zh: '结束', en: 'Kill'},
  },
  montage: {
    caption: {
      zh: 'Hosts、截图、剪贴板、深色、静音、亮度——一套热键。',
      en: 'Hosts, screenshots, clipboard, dark mode, mute, brightness — one set of hotkeys.',
    },
  },
  close: {
    caption: {
      zh: '一颗按键，一扇任意门。',
      en: 'One key. Any door.',
    },
    meta: {zh: '免费 · 开源 · 纯本地 · macOS 14+', en: 'Free · open source · local-only · macOS 14+'},
  },
} as const;

export const t = (value: Bi, lang: Lang) => value[lang];
