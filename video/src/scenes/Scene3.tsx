import type {FC} from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import type {Lang} from '../copy';
import {copy} from '../copy';
import {theme} from '../theme';
import {CaptionChip} from '../ui/CaptionChip';
import {PortManager} from '../ui/PortManager';

export const Scene3: FC<{lang: Lang}> = ({lang}) => {
  const frame = useCurrentFrame();

  return (
    <AbsoluteFill
      style={{
        alignItems: 'center',
        justifyContent: 'center',
        background: theme.gradients.backdrop,
        color: theme.colors.text,
        fontFamily: theme.fonts.sans,
        fontSize: 56,
        fontWeight: 700,
      }}
    >
      <PortManager frame={frame} lang={lang} />
      <CaptionChip text={copy.ports.caption} lang={lang} from={10} to={26} />
    </AbsoluteFill>
  );
};
