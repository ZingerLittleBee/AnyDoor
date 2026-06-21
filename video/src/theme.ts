export const theme = {
  colors: {
    bg: '#050507',
    surface: 'rgba(28, 28, 32, 0.85)',
    line: 'rgba(255, 255, 255, 0.08)',
    lineStrong: 'rgba(255, 255, 255, 0.14)',
    text: '#f5f5f7',
    textDim: '#a1a1aa',
    textSoft: '#909099',
    accent: '#0a84ff',
    accent2: '#5e9bff',
    green: '#30d158',
    orange: '#ff9f0a',
    red: '#ff453a',
    purple: '#bf5af2',
    pink: '#ff375f',
  },
  fonts: {
    sans: '-apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "PingFang SC", "Helvetica Neue", Inter, "Noto Sans SC", system-ui, sans-serif',
    mono: 'ui-monospace, "SF Mono", "JetBrains Mono", Menlo, monospace',
  },
  gradients: {
    backdrop:
      'radial-gradient(900px 600px at 80% -10%, rgba(10,132,255,.18), transparent 60%), radial-gradient(900px 600px at -10% 30%, rgba(191,90,242,.10), transparent 60%), radial-gradient(700px 500px at 50% 110%, rgba(48,209,88,.06), transparent 70%), #050507',
    accentText: 'linear-gradient(135deg, #5e9bff 0%, #bf5af2 60%, #ff375f 110%)',
    panel: 'linear-gradient(180deg, rgba(38,38,42,.92), rgba(22,22,26,.92))',
    desktop:
      'radial-gradient(120% 80% at 30% 30%, rgba(94,155,255,.45), transparent 60%), radial-gradient(110% 70% at 75% 75%, rgba(191,90,242,.40), transparent 60%), radial-gradient(90% 60% at 50% 110%, rgba(255,55,95,.20), transparent 60%), linear-gradient(160deg, #1a1a2e 0%, #16213e 40%, #0f0f1e 100%)',
  },
  shadow: {
    panel:
      '0 0 0 .5px rgba(255,255,255,.06) inset, 0 30px 80px rgba(0,0,0,.6), 0 8px 28px rgba(0,0,0,.4)',
    stage: '0 40px 100px rgba(0,0,0,.5)',
  },
} as const;

export type Theme = typeof theme;
