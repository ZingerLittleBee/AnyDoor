import type {FC} from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import type {Lang} from '../copy';
import {copy, t} from '../copy';
import {clamp} from '../timing';
import {theme} from '../theme';
import {Backdrop} from '../ui/Backdrop';
import {DoorGlyph} from '../ui/DoorGlyph';
import {Keycap} from '../ui/Keycap';
import {MenuPanel} from '../ui/MenuPanel';

export const Scene5: FC<{lang: Lang}> = ({lang}) => {
  const frame = useCurrentFrame();
  const returnFrame = frame >= 156 ? clamp(frame, [156, 214], [36, 0]) : undefined;
  const panelScale = frame < 156 ? clamp(frame, [0, 80], [1.08, 0.86]) : clamp(frame, [156, 214], [0.86, 0.72]);
  const panelY = frame < 156 ? clamp(frame, [0, 80], [26, -84]) : clamp(frame, [156, 214], [-84, 34]);
  const panelOpacity = frame < 156 ? 1 : clamp(frame, [156, 214], [1, 0]);
  const headlineOpacity = frame < 156 ? clamp(frame, [82, 104], [0, 1]) : clamp(frame, [156, 190], [1, 0]);
  const metaBadges = t(copy.close.meta, lang).split(' · ');

  return (
    <AbsoluteFill
      style={{
        alignItems: 'center',
        justifyContent: 'center',
        color: theme.colors.text,
        fontFamily: theme.fonts.sans,
        fontSize: 56,
        fontWeight: 700,
      }}
    >
      <Backdrop progressFrame={returnFrame} />
      <div
        style={{
          position: 'absolute',
          inset: 0,
          opacity: panelOpacity,
          transform: `translateY(${panelY}px) scale(${panelScale})`,
          transformOrigin: 'center center',
        }}
      >
        <MenuPanel lang={lang} />
      </div>

      <div
        style={{
          position: 'absolute',
          left: 220,
          right: 220,
          bottom: 174,
          opacity: headlineOpacity,
          transform: `translateY(${clamp(frame, [82, 104], [18, 0])}px)`,
          textAlign: 'center',
          fontSize: lang === 'zh' ? 44 : 42,
          fontWeight: 900,
          letterSpacing: 0,
          lineHeight: 1.12,
        }}
      >
        {t(copy.close.caption, lang)}
      </div>

      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          bottom: 98,
          display: 'flex',
          justifyContent: 'center',
          gap: 12,
          opacity: headlineOpacity,
          transform: `translateY(${clamp(frame, [92, 114], [18, 0])}px)`,
        }}
      >
        {metaBadges.map((badge) => (
          <span
            key={badge}
            style={{
              padding: '10px 16px',
              borderRadius: 999,
              border: `1px solid ${theme.colors.lineStrong}`,
              background: 'rgba(16,16,20,.72)',
              boxShadow: '0 14px 34px rgba(0,0,0,.32), 0 0 0 1px rgba(255,255,255,.04) inset',
              color: theme.colors.text,
              fontFamily: theme.fonts.sans,
              fontSize: 20,
              fontWeight: 800,
              lineHeight: 1,
              whiteSpace: 'nowrap',
            }}
          >
            {badge}
          </span>
        ))}
      </div>

      <div
        style={{
          position: 'absolute',
          inset: 0,
          opacity: frame >= 156 ? clamp(frame, [156, 184], [0, 1]) : 0,
        }}
      >
        <DoorGlyph seedOpacity={0.18} progressFrame={returnFrame ?? 0} />
      </div>

      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          bottom: 196,
          display: 'flex',
          justifyContent: 'center',
          opacity: frame >= 156 ? clamp(frame, [186, 214], [0, 1]) : 0,
        }}
      >
        <Keycap label="Hyper Key" width={220} />
      </div>
    </AbsoluteFill>
  );
};
