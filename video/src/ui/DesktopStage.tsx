import type {FC} from 'react';
import {Img, staticFile} from 'remotion';
import {clamp, overshoot} from '../timing';
import {theme} from '../theme';
import type {Lang} from '../copy';
import {AppIcon, type AppIconName} from './AppIcon';

type DesktopAppName = AppIconName;
type DesktopEvent =
  | {kind: 'open'; appName: DesktopAppName; start: number}
  | {kind: 'close'; appName: DesktopAppName; start: number};

type DesktopStageProps = {
  frame: number;
  events: DesktopEvent[];
  lang: Lang;
};

type WindowState = {
  appName: DesktopAppName;
  opacity: number;
  scale: number;
  translateY: number;
};

const apps: Record<
  DesktopAppName,
  {
    label: string;
    tag: Record<Lang, string>;
  }
> = {
  Finder: {
    label: 'Finder',
    tag: {zh: '一键切回访达', en: 'File switch in one press'},
  },
  Safari: {
    label: 'Safari',
    tag: {zh: '一键回到网页', en: 'Back to the web instantly'},
  },
};

const appNames: DesktopAppName[] = ['Finder', 'Safari'];
const trafficLights = ['#ff5f57', '#ffbd2e', '#28c840'];

const latestEventAt = (events: DesktopEvent[], frame: number) =>
  events
    .filter((event) => event.start <= frame)
    .sort((a, b) => b.start - a.start)[0];

const windowStateFor = (frame: number, events: DesktopEvent[]): WindowState | null => {
  const latest = latestEventAt(events, frame);

  if (!latest) {
    return null;
  }

  if (latest.kind === 'open') {
    return {
      appName: latest.appName,
      opacity: clamp(frame, [latest.start, latest.start + 12], [0, 1]),
      scale: clamp(frame, [latest.start, latest.start + 24], [0.84, 1], overshoot),
      translateY: clamp(frame, [latest.start, latest.start + 24], [34, 0], overshoot),
    };
  }

  if (frame > latest.start + 18) {
    return null;
  }

  return {
    appName: latest.appName,
    opacity: clamp(frame, [latest.start, latest.start + 18], [1, 0]),
    scale: clamp(frame, [latest.start, latest.start + 18], [1, 0.96]),
    translateY: clamp(frame, [latest.start, latest.start + 18], [0, 18]),
  };
};

const bounceFor = (frame: number, events: DesktopEvent[], appName: DesktopAppName) => {
  const latestOpen = events
    .filter((event) => event.kind === 'open' && event.appName === appName && event.start <= frame)
    .sort((a, b) => b.start - a.start)[0];

  if (!latestOpen || frame > latestOpen.start + 20) {
    return 0;
  }

  const up = clamp(frame, [latestOpen.start, latestOpen.start + 8], [0, -15], overshoot);
  const down = clamp(frame, [latestOpen.start + 8, latestOpen.start + 20], [-15, 0]);
  return frame <= latestOpen.start + 8 ? up : down;
};

export const DesktopStage: FC<DesktopStageProps> = ({frame, events, lang}) => {
  const latest = latestEventAt(events, frame);
  const activeApp = latest?.kind === 'open' ? latest.appName : null;
  const windowState = windowStateFor(frame, events);

  return (
    <div
      data-ui="desktop-stage"
      style={{
        position: 'relative',
        width: 1180,
        height: 720,
        padding: 8,
        border: `.5px solid ${theme.colors.lineStrong}`,
        borderRadius: 18,
        overflow: 'hidden',
        background: theme.gradients.desktop,
        boxShadow: theme.shadow.stage,
        flex: '0 0 auto',
      }}
    >
      <div
        data-ui="desktop-menubar"
        style={{
          position: 'absolute',
          top: 8,
          left: 8,
          right: 8,
          height: 32,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          padding: '0 14px',
          borderRadius: 10,
          background: 'rgba(245,245,247,.72)',
          color: '#141418',
          fontFamily: theme.fonts.sans,
          fontSize: 14,
          fontWeight: 700,
          boxShadow: '0 1px 0 rgba(255,255,255,.62) inset',
          backdropFilter: 'blur(22px)',
        }}
      >
        <div style={{display: 'flex', alignItems: 'center', gap: 18}}>
          <span style={{fontWeight: 900}}>AnyDoor</span>
          <span>{activeApp ?? (lang === 'zh' ? '桌面' : 'Desktop')}</span>
          <span>{lang === 'zh' ? '文件' : 'File'}</span>
          <span>{lang === 'zh' ? '编辑' : 'Edit'}</span>
          <span>{lang === 'zh' ? '显示' : 'View'}</span>
        </div>
        <div style={{display: 'flex', alignItems: 'center', gap: 10}}>
          <Img src={staticFile('menubar-icon.png')} style={{width: 16, height: 16, objectFit: 'contain'}} />
          <span>9:41</span>
        </div>
      </div>

      {windowState ? (
        <div
          data-ui="desktop-window"
          style={{
            position: 'absolute',
            top: 120,
            left: '50%',
            width: 760,
            height: 440,
            overflow: 'hidden',
            borderRadius: 20,
            border: `.5px solid ${theme.colors.lineStrong}`,
            background: 'linear-gradient(180deg, rgba(245,245,247,.94), rgba(225,229,238,.90))',
            color: '#16161c',
            opacity: windowState.opacity,
            transform: `translateX(-50%) translateY(${windowState.translateY}px) scale(${windowState.scale})`,
            boxShadow: '0 34px 90px rgba(0,0,0,.34)',
          }}
        >
          <div
            style={{
              height: 48,
              display: 'flex',
              alignItems: 'center',
              padding: '0 18px',
              gap: 9,
              borderBottom: '1px solid rgba(0,0,0,.08)',
              background: 'rgba(255,255,255,.38)',
            }}
          >
            {trafficLights.map((color) => (
              <span
                key={color}
                style={{
                  width: 13,
                  height: 13,
                  borderRadius: 999,
                  background: color,
                  boxShadow: '0 0 0 .5px rgba(0,0,0,.12) inset',
                }}
              />
            ))}
          </div>
          <div
            style={{
              height: 392,
              display: 'flex',
              flexDirection: 'column',
              alignItems: 'center',
              justifyContent: 'center',
              gap: 18,
              fontFamily: theme.fonts.sans,
            }}
          >
            <AppIcon name={windowState.appName} size={96} />
            <div style={{fontSize: 34, fontWeight: 800, lineHeight: 1}}>{apps[windowState.appName].label}</div>
            <div style={{fontSize: 20, color: 'rgba(22,22,28,.62)', fontWeight: 700}}>
              {apps[windowState.appName].tag[lang]}
            </div>
          </div>
        </div>
      ) : (
        <div data-ui="desktop-window" style={{display: 'none'}} />
      )}

      <div
        data-ui="desktop-dock"
        style={{
          position: 'absolute',
          left: '50%',
          bottom: 24,
          height: 64,
          display: 'flex',
          alignItems: 'center',
          gap: 10,
          padding: '0 16px',
          borderRadius: 22,
          border: `.5px solid ${theme.colors.lineStrong}`,
          background: 'rgba(245,245,247,.34)',
          backdropFilter: 'blur(28px)',
          transform: 'translateX(-50%)',
          boxShadow: '0 22px 55px rgba(0,0,0,.28), 0 1px 0 rgba(255,255,255,.28) inset',
        }}
      >
        {appNames.map((appName) => {
          const isActive = activeApp === appName;
          return (
            <div
              key={appName}
              style={{
                width: 44,
                height: 54,
                display: 'flex',
                flexDirection: 'column',
                alignItems: 'center',
                justifyContent: 'flex-start',
                gap: 5,
                transform: `translateY(${bounceFor(frame, events, appName)}px)`,
              }}
            >
              <AppIcon name={appName} size={44} />
              <span
                style={{
                  width: 5,
                  height: 5,
                  borderRadius: 999,
                  background: isActive ? 'rgba(255,255,255,.92)' : 'transparent',
                }}
              />
            </div>
          );
        })}
      </div>
    </div>
  );
};
