import type {FC} from 'react';
import {Img, staticFile, useCurrentFrame} from 'remotion';
import {clamp} from '../timing';

type DoorGlyphProps = {
  size?: number;
  seedOpacity?: number;
  fadeInEnd?: number;
  progressFrame?: number;
};

export const DoorGlyph: FC<DoorGlyphProps> = ({
  size = 168,
  seedOpacity = 0,
  fadeInEnd = 28,
  progressFrame,
}) => {
  const currentFrame = useCurrentFrame();
  const frame = progressFrame ?? currentFrame;
  const opacity = clamp(frame, [0, fadeInEnd], [seedOpacity, 1]);
  const scale = clamp(frame, [0, 36], [0.92, 1]);

  return (
    <Img
      src={staticFile('menubar-icon.png')}
      style={{
        position: 'absolute',
        top: 206,
        left: '50%',
        width: size,
        height: size,
        objectFit: 'contain',
        opacity,
        transform: `translateX(-50%) scale(${scale})`,
        filter: 'drop-shadow(0 24px 72px rgba(94,155,255,.38))',
      }}
    />
  );
};
