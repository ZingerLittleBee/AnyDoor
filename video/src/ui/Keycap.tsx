import type {FC} from 'react';
import {theme} from '../theme';

type KeycapProps = {
  label: string;
  pressed?: boolean;
  glow?: boolean;
  width?: number;
};

export const Keycap: FC<KeycapProps> = ({label, pressed = false, glow = false, width = 74}) => (
  <div
    style={{
      width,
      height: 54,
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      border: `1px solid ${pressed ? 'rgba(94,155,255,.72)' : theme.colors.lineStrong}`,
      borderRadius: 13,
      background: pressed
        ? 'linear-gradient(180deg, rgba(94,155,255,.34), rgba(10,132,255,.20))'
        : 'linear-gradient(180deg, rgba(255,255,255,.13), rgba(255,255,255,.055))',
      boxShadow: glow
        ? '0 0 42px rgba(94,155,255,.46), 0 10px 28px rgba(0,0,0,.34), 0 1px 0 rgba(255,255,255,.16) inset'
        : '0 10px 24px rgba(0,0,0,.30), 0 1px 0 rgba(255,255,255,.14) inset',
      color: pressed ? theme.colors.text : theme.colors.textDim,
      fontFamily: theme.fonts.sans,
      fontSize: label.length > 5 ? 18 : 22,
      fontWeight: 800,
      letterSpacing: 0,
      lineHeight: 1,
      transform: pressed ? 'translateY(3px)' : 'translateY(0)',
    }}
  >
    {label}
  </div>
);
