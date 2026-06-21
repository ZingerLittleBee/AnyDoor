import type {FC} from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import type {Lang} from '../copy';
import {copy} from '../copy';
import {theme} from '../theme';
import {Backdrop} from '../ui/Backdrop';
import {CaptionChip} from '../ui/CaptionChip';
import {DoorGlyph} from '../ui/DoorGlyph';
import {Keycap} from '../ui/Keycap';

export const Scene0: FC<{lang: Lang}> = ({lang}) => {
  const frame = useCurrentFrame();
  const pressed = frame >= 42 && frame <= 58;

  return (
    <AbsoluteFill
      style={{
        alignItems: 'center',
        justifyContent: 'center',
        color: theme.colors.text,
        fontFamily: theme.fonts.sans,
      }}
    >
      <Backdrop />
      <DoorGlyph seedOpacity={0.18} />
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          bottom: 470,
          display: 'flex',
          justifyContent: 'center',
        }}
      >
        <Keycap label="Hyper Key" pressed={pressed} glow={pressed} width={220} />
      </div>
      <CaptionChip text={copy.coldOpen.caption} lang={lang} from={34} to={52} />
    </AbsoluteFill>
  );
};
