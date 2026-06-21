import type {FC} from 'react';
import {useCurrentFrame} from 'remotion';
import type {Bi, Lang} from '../copy';
import {t} from '../copy';
import {clamp} from '../timing';
import {theme} from '../theme';

type CaptionChipProps = {
  text: Bi;
  lang: Lang;
  from?: number;
  to?: number;
};

export const CaptionChip: FC<CaptionChipProps> = ({text, lang, from = 8, to = 34}) => {
  const frame = useCurrentFrame();
  const opacity = clamp(frame, [from, to], [0, 1]);
  const y = clamp(frame, [from, to], [18, 0]);

  return (
    <div
      style={{
        position: 'absolute',
        left: '50%',
        bottom: 72,
        transform: `translate(-50%, ${y}px)`,
        opacity,
        padding: '16px 28px',
        border: `1px solid ${theme.colors.lineStrong}`,
        borderRadius: 999,
        background: 'rgba(16,16,20,.72)',
        boxShadow: '0 18px 48px rgba(0,0,0,.38), 0 0 0 1px rgba(255,255,255,.04) inset',
        color: theme.colors.text,
        fontFamily: theme.fonts.sans,
        fontSize: lang === 'zh' ? 28 : 26,
        fontWeight: 700,
        letterSpacing: 0,
        lineHeight: 1.18,
        whiteSpace: 'nowrap',
      }}
    >
      {t(text, lang)}
    </div>
  );
};
