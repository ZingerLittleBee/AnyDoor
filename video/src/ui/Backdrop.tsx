import type {FC} from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {clamp} from '../timing';
import {theme} from '../theme';

type BackdropProps = {
  dim?: number;
  progressFrame?: number;
};

export const Backdrop: FC<BackdropProps> = ({dim = 0.18, progressFrame}) => {
  const currentFrame = useCurrentFrame();
  const frame = progressFrame ?? currentFrame;
  const gridOpacity = clamp(frame, [0, 45], [0.2, 0.5]);

  return (
    <AbsoluteFill style={{background: theme.gradients.backdrop}}>
      <AbsoluteFill
        style={{
          backgroundImage: 'radial-gradient(circle, rgba(255,255,255,.24) 1px, transparent 1px)',
          backgroundPosition: 'center',
          backgroundSize: '34px 34px',
          mixBlendMode: 'screen',
          opacity: gridOpacity,
        }}
      />
      <AbsoluteFill style={{backgroundColor: `rgba(0,0,0,${dim})`}} />
    </AbsoluteFill>
  );
};
