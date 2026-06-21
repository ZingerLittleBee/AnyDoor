import type {FC} from 'react';
import {theme} from '../theme';
import {Keycap} from './Keycap';

type KeyboardProps = {
  pressedKeys?: string[];
};

const rows = [
  ['Esc', 'F1', 'F2', 'F3', 'F4', 'F5', 'F6'],
  ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'Return'],
  ['Hyper Key'],
] as const;

const widthFor = (label: string) => {
  if (label === 'Hyper Key') {
    return 220;
  }
  if (label === 'Space') {
    return 260;
  }
  if (label === 'Return') {
    return 120;
  }
  if (label === 'Esc') {
    return 84;
  }
  return 74;
};

export const Keyboard: FC<KeyboardProps> = ({pressedKeys = []}) => {
  const pressed = new Set(pressedKeys);

  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        gap: 14,
        padding: 24,
        border: `1px solid ${theme.colors.lineStrong}`,
        borderRadius: 24,
        background: 'linear-gradient(180deg, rgba(34,34,40,.78), rgba(14,14,18,.82))',
        boxShadow: theme.shadow.panel,
      }}
    >
      {rows.map((row, rowIndex) => (
        <div
          key={`row-${rowIndex}`}
          style={{
            display: 'flex',
            justifyContent: 'center',
            gap: 12,
          }}
        >
          {row.map((label, keyIndex) => (
            <Keycap
              key={`key-${rowIndex}-${keyIndex}`}
              label={label}
              pressed={pressed.has(label)}
              glow={pressed.has(label)}
              width={widthFor(label)}
            />
          ))}
        </div>
      ))}
    </div>
  );
};
