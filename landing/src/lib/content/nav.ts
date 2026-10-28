// Copy for the sticky nav.
import type { Bi } from '../i18n';

export const nav = {
  pn: { zh: '任意门 · AD-1', en: 'AD-1 · ANY DOOR' },
  navAria: { zh: '页面导航', en: 'Page sections' },
  langAria: { zh: '界面语言', en: 'Language' },
  download: { zh: '下载', en: 'Download' },
  links: [
    { href: '#demo', label: { zh: '演示', en: 'Demo' } },
    { href: '#why', label: { zh: '为什么', en: 'Why' } },
    { href: '#board', label: { zh: '功能', en: 'Features' } },
    { href: '#capture', label: { zh: '截图', en: 'Capture' } },
    { href: '#faq', label: { zh: 'FAQ', en: 'FAQ' } },
  ] as { href: string; label: Bi }[],
};
