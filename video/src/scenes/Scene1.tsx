import type {FC} from 'react';
import {AbsoluteFill, useCurrentFrame} from 'remotion';
import type {Lang} from '../copy';
import {copy} from '../copy';
import {clamp} from '../timing';
import {theme} from '../theme';
import {CaptionChip} from '../ui/CaptionChip';
import {DesktopStage} from '../ui/DesktopStage';
import {Keyboard} from '../ui/Keyboard';

export const Scene1: FC<{lang: Lang}> = ({lang}) => {
  const frame = useCurrentFrame();
  const hotkeyPressed =
    (frame >= 30 && frame <= 54) || (frame >= 104 && frame <= 128) || (frame >= 132 && frame <= 156);
  const keyboardOpacity = clamp(frame, [14, 30], [0, 1]);

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
      <DesktopStage
        frame={frame}
        lang={lang}
        events={[
          {kind: 'open', appName: 'Finder', start: 30},
          {kind: 'close', appName: 'Finder', start: 104},
          {kind: 'open', appName: 'Safari', start: 132},
        ]}
      />
      <div
        style={{
          position: 'absolute',
          right: 170,
          bottom: 168,
          opacity: keyboardOpacity,
          transform: `scale(.46) translateY(${clamp(frame, [14, 30], [24, 0])}px)`,
          transformOrigin: 'right bottom',
        }}
      >
        <Keyboard pressedKeys={hotkeyPressed ? ['Hyper Key'] : []} />
      </div>
      <CaptionChip text={copy.hotkey.caption} lang={lang} from={14} to={30} />
    </AbsoluteFill>
  );
};
