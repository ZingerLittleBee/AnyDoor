import {continueRender, delayRender, getRemotionEnvironment} from 'remotion';
import {loadFont as loadInter} from '@remotion/google-fonts/Inter';
import {loadFont as loadJetBrainsMono} from '@remotion/google-fonts/JetBrainsMono';
import {loadFont as loadNotoSansSC} from '@remotion/google-fonts/NotoSansSC';

let loaded = false;

export const loadFonts = () => {
  if (loaded) {
    return;
  }
  loaded = true;

  if (typeof document === 'undefined') {
    return;
  }

  // The theme font stack leads with the macOS system fonts (SF Pro / PingFang SC
  // / SF Mono), which come *before* Inter / Noto Sans SC / JetBrains Mono. On the
  // macOS render machine every glyph (Latin, CJK, the ⌘⌥⇧⌃ keycaps, ¥, arrows)
  // is therefore served by a system font, and the Google webfonts are never
  // actually selected. Loading them anyway is pure waste during a render: Noto
  // Sans SC alone fans out to ~388 unicode-range subset requests, and across the
  // default 8 render tabs that saturates the connection pool until a single font
  // face trips @remotion/google-fonts' internal 18s load timeout (which Remotion's
  // --timeout does not govern), intermittently failing the whole render.
  //
  // So during rendering we skip the network webfonts entirely and only warm the
  // local system fonts. The Google webfonts are still loaded in Studio / preview
  // (non-rendering), where a non-macOS viewer would otherwise miss the CJK glyphs.
  const handle = delayRender('Load promo fonts');
  const systemFonts = [
    document.fonts.load('700 96px "SF Pro Display"'),
    document.fonts.load('500 42px "SF Pro Text"'),
    document.fonts.load('600 42px "PingFang SC"'),
    document.fonts.load('600 28px "SF Mono"'),
  ];

  const webFonts = getRemotionEnvironment().isRendering
    ? []
    : [
        loadInter('normal', {weights: ['400', '500', '600', '700'], subsets: ['latin']}).waitUntilDone(),
        loadNotoSansSC('normal', {
          weights: ['400', '500', '600', '700'],
          subsets: ['chinese-simplified'],
        }).waitUntilDone(),
        loadJetBrainsMono('normal', {weights: ['500', '600', '700'], subsets: ['latin']}).waitUntilDone(),
      ];

  Promise.all([...systemFonts, ...webFonts])
    .catch(() => undefined)
    .finally(() => continueRender(handle));
};
