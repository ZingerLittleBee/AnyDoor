import type {FC} from 'react';
import type {Lang} from '../copy';
import {copy, t} from '../copy';
import {clamp} from '../timing';
import {theme} from '../theme';

type CommandPaletteProps = {
  frame: number;
  lang: Lang;
};

const typedText = (text: string, frame: number, start: number, step = 3) => {
  const length = Math.max(0, Math.min(text.length, Math.floor((frame - start) / step) + 1));
  return text.slice(0, length);
};

export const CommandPalette: FC<CommandPaletteProps> = ({frame, lang}) => {
  const enter = clamp(frame, [0, 18], [0, 1]);
  const showingConvert = frame >= 105;
  const query = showingConvert
    ? typedText(copy.palette.queryConvert, frame, 105, 2)
    : typedText(copy.palette.queryCalc, frame, 24);
  // The calc result fades out as the currency query is typed, then the
  // conversion result fades in — a re-query in place, not a second block.
  const calcOpacity = showingConvert ? clamp(frame, [105, 113], [1, 0]) : clamp(frame, [58, 72], [0, 1]);
  const convertOpacity = clamp(frame, [132, 144], [0, 1]);

  return (
    <div
      data-ui="command-palette"
      style={{
        position: 'absolute',
        top: 250,
        left: '50%',
        width: 980,
        minHeight: 168,
        borderRadius: 20,
        border: `.5px solid ${theme.colors.lineStrong}`,
        background: 'rgba(28,28,32,.82)',
        color: theme.colors.text,
        fontFamily: theme.fonts.sans,
        overflow: 'hidden',
        boxShadow: theme.shadow.panel,
        backdropFilter: 'blur(28px)',
        opacity: enter,
        transform: `translateX(-50%) scale(${clamp(frame, [0, 18], [0.96, 1])})`,
      }}
    >
      <div
        data-ui="palette-search"
        style={{
          height: 82,
          display: 'flex',
          alignItems: 'center',
          gap: 18,
          padding: '0 28px',
          borderBottom: `1px solid ${theme.colors.line}`,
        }}
      >
        <div
          style={{
            width: 24,
            height: 24,
            border: `3px solid ${theme.colors.textDim}`,
            borderRadius: 999,
            position: 'relative',
            flex: '0 0 auto',
          }}
        >
          <span
            style={{
              position: 'absolute',
              width: 10,
              height: 3,
              right: -7,
              bottom: -4,
              borderRadius: 999,
              background: theme.colors.textDim,
              transform: 'rotate(45deg)',
            }}
          />
        </div>
        <div
          style={{
            minWidth: 0,
            flex: 1,
            fontFamily: theme.fonts.mono,
            fontSize: 34,
            fontWeight: 800,
            whiteSpace: 'nowrap',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
          }}
        >
          {query}
          <span style={{color: theme.colors.accent2}}>|</span>
        </div>
      </div>

      <div data-ui="palette-result" style={{position: 'relative', height: 86}}>
        <div
          style={{
            position: 'absolute',
            inset: 0,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '0 28px',
            opacity: calcOpacity,
            transform: `translateY(${clamp(frame, [58, 72], [8, 0])}px)`,
          }}
        >
          <div style={{fontSize: 20, color: theme.colors.textDim, fontWeight: 700}}>
            {lang === 'zh' ? '计算结果' : 'Calculator'}
          </div>
          <div style={{fontFamily: theme.fonts.mono, fontSize: 42, fontWeight: 900}}>{copy.palette.resultCalc}</div>
        </div>

        <div
          data-ui="palette-convert"
          style={{
            position: 'absolute',
            inset: 0,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '0 28px',
            opacity: convertOpacity,
            transform: `translateY(${clamp(frame, [132, 144], [8, 0])}px)`,
          }}
        >
          <div style={{fontSize: 20, color: theme.colors.textDim, fontWeight: 700}}>
            {t(copy.palette.convertLabel, lang)}
          </div>
          <div style={{fontFamily: theme.fonts.mono, fontSize: 42, fontWeight: 900}}>
            {copy.palette.convertResult}
          </div>
        </div>
      </div>
    </div>
  );
};
