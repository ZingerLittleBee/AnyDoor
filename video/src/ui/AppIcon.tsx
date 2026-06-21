import type {FC} from 'react';

export type AppIconName = 'Finder' | 'Safari';

type AppIconProps = {
  name: AppIconName;
  size?: number;
};

const FinderGlyph: FC = () => (
  <>
    <defs>
      <linearGradient id="finder-left" x1="0" x2="0" y1="0" y2="1">
        <stop offset="0%" stopColor="#36b8ff" />
        <stop offset="100%" stopColor="#1688ff" />
      </linearGradient>
      <linearGradient id="finder-right" x1="0" x2="0" y1="0" y2="1">
        <stop offset="0%" stopColor="#d7fbff" />
        <stop offset="100%" stopColor="#58e0ff" />
      </linearGradient>
    </defs>
    <rect width="96" height="96" rx="23" fill="url(#finder-left)" />
    <path d="M48 0h25c13 0 23 10 23 23v50c0 13-10 23-23 23H48z" fill="url(#finder-right)" />
    <rect x="3" y="3" width="90" height="90" rx="20" fill="none" stroke="rgba(255,255,255,.42)" strokeWidth="2" />
    <path d="M48 16v64" stroke="rgba(255,255,255,.58)" strokeWidth="3" />
    <circle cx="34" cy="45" r="4" fill="#06356e" />
    <circle cx="62" cy="45" r="4" fill="#06356e" />
    <path d="M36 61q12 10 24 0" stroke="#06356e" strokeWidth="4.5" fill="none" strokeLinecap="round" />
  </>
);

const SafariGlyph: FC = () => (
  <>
    <defs>
      <radialGradient id="safari-bg" cx=".45" cy=".35" r=".74">
        <stop offset="0%" stopColor="#9df2ff" />
        <stop offset="42%" stopColor="#10a7ff" />
        <stop offset="100%" stopColor="#0752d6" />
      </radialGradient>
      <linearGradient id="safari-needle" x1="0" x2="1" y1="0" y2="1">
        <stop offset="0%" stopColor="#ff4656" />
        <stop offset="100%" stopColor="#f7fbff" />
      </linearGradient>
    </defs>
    <rect width="96" height="96" rx="23" fill="url(#safari-bg)" />
    <rect x="3" y="3" width="90" height="90" rx="20" fill="none" stroke="rgba(255,255,255,.38)" strokeWidth="2" />
    <circle cx="48" cy="48" r="30" fill="rgba(255,255,255,.08)" stroke="rgba(255,255,255,.82)" strokeWidth="4" />
    <path d="M48 18v8M48 70v8M18 48h8M70 48h8" stroke="#f7fbff" strokeWidth="4" strokeLinecap="round" />
    <path d="M62 24 53 54 24 62 43 43z" fill="url(#safari-needle)" />
    <path d="M62 24 53 54 43 43z" fill="#ff4656" />
    <circle cx="48" cy="48" r="5" fill="#f7fbff" />
  </>
);

export const AppIcon: FC<AppIconProps> = ({name, size = 96}) => {
  const shape = name === 'Finder' ? 'finder-face' : 'safari-compass';

  return (
    <svg
      data-app-icon={name}
      data-app-icon-shape={shape}
      data-app-icon-treatment="minimal-aqua"
      viewBox="0 0 96 96"
      width={size}
      height={size}
      role="img"
      aria-label={name}
      style={{
        display: 'block',
        filter: 'drop-shadow(0 14px 24px rgba(0,0,0,.18))',
      }}
    >
      {name === 'Finder' ? <FinderGlyph /> : <SafariGlyph />}
    </svg>
  );
};
