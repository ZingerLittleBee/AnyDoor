import type {FC, ReactNode} from 'react';
import type {Lang} from '../copy';
import {clamp} from '../timing';
import {theme} from '../theme';

type SystemMontageProps = {
  frame: number;
  lang: Lang;
};

type BeatCardProps = {
  children: ReactNode;
  dataUi: string;
  frame: number;
  range: [number, number];
};

const beatOpacity = (frame: number, [start, end]: [number, number]) => {
  // Cross-fade into the previous beat: the fade-in begins 7 frames before this
  // beat's start so adjacent beats overlap instead of both hitting 0 at the
  // shared boundary frame, which previously flashed an empty stage between beats.
  const fadeInStart = start > 0 ? start - 7 : start;
  const fadeIn = clamp(frame, [fadeInStart, fadeInStart + 7], [0, 1]);
  const fadeOut = clamp(frame, [end - 7, end], [1, 0]);
  return Math.min(fadeIn, fadeOut);
};

const BeatCard: FC<BeatCardProps> = ({children, dataUi, frame, range}) => {
  const opacity = beatOpacity(frame, range);
  return (
    <div
      data-ui={dataUi}
      style={{
        position: 'absolute',
        top: '50%',
        left: '50%',
        width: 720,
        height: 340,
        borderRadius: 18,
        border: `.5px solid ${theme.colors.lineStrong}`,
        background: 'rgba(28,28,32,.84)',
        boxShadow: theme.shadow.panel,
        color: theme.colors.text,
        fontFamily: theme.fonts.sans,
        opacity,
        transform: `translate(-50%, calc(-50% + ${clamp(frame, [range[0], range[0] + 12], [20, 0])}px))`,
      }}
    >
      {children}
    </div>
  );
};

const headingFor = (lang: Lang, zh: string, en: string) => (lang === 'zh' ? zh : en);

type CaptureModePreview = {
  zh: string;
  en: string;
};

const captureModes: CaptureModePreview[] = [
  {zh: '区域', en: 'Region'},
  {zh: '窗口', en: 'Window'},
  {zh: '全屏', en: 'Fullscreen'},
  {zh: '定时', en: 'Timer'},
  {zh: '滚动截图', en: 'Scrolling'},
  {zh: '录屏', en: 'Record'},
];

const captureModeActiveIndex = (frame: number) => {
  const start = 45;
  const duration = 48;
  const progress = Math.max(0, Math.min(0.999, (frame - start) / duration));
  return Math.floor(progress * captureModes.length);
};

export const SystemMontage: FC<SystemMontageProps> = ({frame, lang}) => {
  const activeCaptureModeIndex = captureModeActiveIndex(frame);
  // Triangle ramp: darken the desktop as the toggle slides on, then release it
  // before the dark-mode beat hands off to the mute beat, so the boundary is not
  // pinned at full black while the cards cross-fade.
  const darken = clamp(frame, [134, 150], [0, 1]) - clamp(frame, [150, 160], [0, 1]);
  const brightness = Math.round(clamp(frame, [190, 220], [42, 78]));
  const activeBars = Math.round((brightness / 100) * 12);

  return (
    <div
      data-ui="system-montage"
      style={{
        position: 'absolute',
        top: '50%',
        left: '50%',
        width: 1120,
        height: 620,
        borderRadius: 22,
        overflow: 'hidden',
        border: `.5px solid ${theme.colors.lineStrong}`,
        background: theme.gradients.desktop,
        boxShadow: theme.shadow.stage,
        transform: 'translate(-50%, -50%)',
      }}
    >
      <div
        style={{
          position: 'absolute',
          inset: 0,
          background: '#030306',
          opacity: darken,
        }}
      />

      <BeatCard dataUi="hosts-beat" frame={frame} range={[0, 30]}>
        <div style={{padding: 28}}>
          <div style={{fontSize: 30, fontWeight: 900, marginBottom: 30}}>
            {headingFor(lang, 'Hosts 配置切换', 'Hosts profile switch')}
          </div>
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: '1fr 60px 1fr',
              alignItems: 'center',
              gap: 18,
              fontFamily: theme.fonts.mono,
              fontSize: 24,
              fontWeight: 900,
            }}
          >
            <div
              style={{
                padding: '24px 18px',
                borderRadius: 16,
                background: 'rgba(255,255,255,.08)',
                color: theme.colors.textDim,
                textAlign: 'center',
              }}
            >
              local.dev
            </div>
            <div style={{color: theme.colors.accent2, textAlign: 'center'}}>→</div>
            <div
              style={{
                padding: '24px 18px',
                borderRadius: 16,
                background: 'rgba(94,155,255,.22)',
                color: theme.colors.text,
                textAlign: 'center',
                transform: `scale(${clamp(frame, [10, 24], [0.94, 1])})`,
              }}
            >
              api.dev
            </div>
          </div>
        </div>
      </BeatCard>

      <BeatCard dataUi="screenshot-beat" frame={frame} range={[30, 100]}>
        <div style={{padding: 28}}>
          <div style={{fontSize: 30, fontWeight: 900, marginBottom: 22}}>
            {headingFor(lang, '截图到剪贴板', 'Screenshot to Clipboard')}
          </div>
          <div
            style={{
              position: 'relative',
              width: 526,
              height: 206,
              margin: '0 auto',
              borderRadius: 20,
              background: 'linear-gradient(135deg, rgba(94,155,255,.18), rgba(28,28,34,.88) 48%, rgba(191,90,242,.14))',
              border: `.5px solid ${theme.colors.lineStrong}`,
              overflow: 'hidden',
              boxShadow: 'inset 0 1px 0 rgba(255,255,255,.08)',
            }}
          >
            <div
              style={{
                position: 'absolute',
                inset: 0,
                background:
                  'radial-gradient(circle at 24% 28%, rgba(94,155,255,.22), transparent 34%), radial-gradient(circle at 80% 76%, rgba(191,90,242,.18), transparent 36%)',
              }}
            />
            <div
              data-ui="capture-selection-frame"
              style={{
                position: 'absolute',
                left: 58,
                right: 58,
                top: 30,
                height: 100,
                border: `3px dashed ${theme.colors.accent2}`,
                borderRadius: 18,
                background: 'rgba(94,155,255,.08)',
                boxShadow: '0 0 0 999px rgba(0,0,0,.18), 0 0 34px rgba(94,155,255,.42)',
                transform: `scale(${clamp(frame, [36, 52], [0.92, 1])})`,
                transformOrigin: 'center center',
              }}
            >
              {[
                ['left', 'top'],
                ['right', 'top'],
                ['left', 'bottom'],
                ['right', 'bottom'],
              ].map(([x, y]) => (
                <div
                  key={`${x}-${y}`}
                  style={{
                    position: 'absolute',
                    [x]: -7,
                    [y]: -7,
                    width: 14,
                    height: 14,
                    borderRadius: 999,
                    background: theme.colors.accent2,
                    boxShadow: '0 0 18px rgba(94,155,255,.74)',
                  }}
                />
              ))}
            </div>
            <div
              data-ui="capture-mode-bar"
              style={{
                position: 'absolute',
                left: 24,
                right: 24,
                bottom: 18,
                display: 'grid',
                gridTemplateColumns: 'repeat(6, 1fr)',
                gap: 8,
                transform: `translateY(${clamp(frame, [42, 56], [12, 0])}px)`,
              }}
            >
              {captureModes.map((mode, index) => {
                const active = index === activeCaptureModeIndex;
                return (
                  <div
                    key={mode.zh}
                    data-active-capture-mode={active ? mode.zh : undefined}
                    style={{
                      height: 38,
                      borderRadius: 12,
                      border: `.5px solid ${active ? 'rgba(94,155,255,.82)' : theme.colors.line}`,
                      background: active ? 'rgba(94,155,255,.22)' : 'rgba(255,255,255,.08)',
                      color: active ? theme.colors.text : theme.colors.textDim,
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'center',
                      fontSize: lang === 'zh' ? 14 : 12,
                      fontWeight: 900,
                      boxShadow: active ? '0 12px 28px rgba(10,132,255,.26), inset 0 1px 0 rgba(255,255,255,.18)' : 'none',
                      opacity: clamp(frame, [40, 45], [0, 1]),
                      transform: active ? 'translateY(-2px)' : 'translateY(0)',
                    }}
                  >
                    {headingFor(lang, mode.zh, mode.en)}
                  </div>
                );
              })}
            </div>
          </div>
        </div>
      </BeatCard>

      <BeatCard dataUi="clipboard-beat" frame={frame} range={[100, 130]}>
        <div style={{padding: 28}}>
          <div style={{fontSize: 30, fontWeight: 900, marginBottom: 22}}>
            {headingFor(lang, '剪贴板历史', 'Clipboard history')}
          </div>
          <div
            style={{
              display: 'grid',
              gridTemplateColumns: 'repeat(3, 1fr)',
              gap: 14,
            }}
          >
            {[
              {
                label: headingFor(lang, '截图', 'Shot'),
                color: theme.colors.accent,
              },
              {label: 'URL', color: theme.colors.green},
              {
                label: headingFor(lang, '颜色', 'Color'),
                color: theme.colors.pink,
              },
            ].map((item, index) => (
              <div
                key={item.label}
                style={{
                  height: 170,
                  padding: 16,
                  borderRadius: 18,
                  border: `.5px solid ${theme.colors.lineStrong}`,
                  background: index === 0 ? 'rgba(94,155,255,.18)' : 'rgba(255,255,255,.08)',
                  boxShadow: index === 0 ? '0 18px 44px rgba(10,132,255,.26)' : 'none',
                  transform: `translateY(${clamp(frame, [106 + index * 4, 118 + index * 4], [20, 0])}px)`,
                }}
              >
                <div
                  style={{
                    width: '100%',
                    height: 90,
                    borderRadius: 14,
                    background:
                      index === 0 ? 'linear-gradient(135deg, rgba(94,155,255,.72), rgba(191,90,242,.68))' : item.color,
                    marginBottom: 14,
                  }}
                />
                <div style={{fontSize: 18, fontWeight: 900}}>{item.label}</div>
              </div>
            ))}
          </div>
        </div>
      </BeatCard>

      <BeatCard dataUi="dark-mode-beat" frame={frame} range={[130, 160]}>
        <div
          style={{
            padding: '0 28px',
            height: '100%',
            display: 'flex',
            flexDirection: 'column',
            justifyContent: 'center',
            gap: 34,
          }}
        >
          <div style={{fontSize: 30, fontWeight: 900}}>
            {headingFor(lang, '深色模式', 'Dark Mode')}
          </div>
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              gap: 28,
            }}
          >
            <span style={{fontSize: 72, lineHeight: 1}}>☀</span>
            <div
              style={{
                width: 128,
                height: 66,
                padding: 6,
                borderRadius: 999,
                background: 'rgba(255,255,255,.16)',
                border: `.5px solid ${theme.colors.lineStrong}`,
              }}
            >
              <div
                style={{
                  width: 54,
                  height: 54,
                  borderRadius: 999,
                  background: theme.colors.accent,
                  transform: `translateX(${clamp(frame, [136, 152], [0, 62])}px)`,
                  boxShadow: '0 12px 28px rgba(10,132,255,.42)',
                }}
              />
            </div>
            <span style={{fontSize: 72, lineHeight: 1}}>☾</span>
          </div>
        </div>
      </BeatCard>

      <BeatCard dataUi="mute-beat" frame={frame} range={[160, 190]}>
        <div style={{padding: 28}}>
          <div style={{fontSize: 30, fontWeight: 900, marginBottom: 30}}>
            {headingFor(lang, '系统静音', 'System mute')}
          </div>
          <div
            style={{
              position: 'relative',
              width: 280,
              height: 180,
              margin: '0 auto',
            }}
          >
            <svg
              data-ui="mute-speaker-icon"
              viewBox="0 0 240 160"
              style={{
                width: 280,
                height: 180,
                display: 'block',
                overflow: 'visible',
              }}
            >
              <g
                style={{
                  transform: `translateY(${clamp(frame, [162, 176], [10, 0])}px) scale(${clamp(frame, [162, 176], [0.94, 1])})`,
                  transformOrigin: '120px 80px',
                }}
              >
                <path
                  data-ui="mute-speaker-body"
                  d="M45 66h34c5 0 9 4 9 9v10c0 5-4 9-9 9H45c-8 0-14-6-14-14s6-14 14-14Z"
                  fill="rgba(245,245,247,.96)"
                  style={{filter: 'drop-shadow(0 12px 24px rgba(0,0,0,.22))'}}
                />
                <path
                  data-ui="mute-speaker-cone"
                  d="M83 67 123 39c8-6 19 0 19 10v62c0 10-11 16-19 10L83 93Z"
                  fill="rgba(245,245,247,.98)"
                  style={{filter: 'drop-shadow(0 12px 24px rgba(0,0,0,.18))'}}
                />
                <path
                  data-ui="mute-speaker-wave"
                  d="M158 57c13 12 13 34 0 46"
                  fill="none"
                  stroke="rgba(245,245,247,.62)"
                  strokeWidth="10"
                  strokeLinecap="round"
                />
                <path
                  data-ui="mute-speaker-wave"
                  d="M176 42c25 22 25 54 0 76"
                  fill="none"
                  stroke="rgba(245,245,247,.34)"
                  strokeWidth="10"
                  strokeLinecap="round"
                />
              </g>
              <path
                data-ui="mute-speaker-slash"
                d="M178 42 70 120"
                stroke={theme.colors.red}
                strokeWidth="12"
                strokeLinecap="round"
                strokeDasharray="146"
                strokeDashoffset={146 - clamp(frame, [168, 184], [0, 146])}
                style={{filter: 'drop-shadow(0 10px 18px rgba(255,69,58,.34))'}}
              />
            </svg>
            <div
              style={{
                position: 'absolute',
                left: 30,
                right: 30,
                bottom: -8,
                height: 18,
                borderRadius: 999,
                background: 'radial-gradient(ellipse at center, rgba(255,69,58,.22), transparent 70%)',
              }}
            />
          </div>
        </div>
      </BeatCard>

      <BeatCard dataUi="brightness-beat" frame={frame} range={[190, 220]}>
        <div style={{padding: 28}}>
          <div style={{fontSize: 30, fontWeight: 900, marginBottom: 26}}>
            {headingFor(lang, '外接显示器亮度', 'External display brightness')}
          </div>
          <div
            style={{
              width: 420,
              margin: '0 auto',
              padding: 24,
              borderRadius: 22,
              background: 'rgba(245,245,247,.88)',
              color: '#17171c',
              boxShadow: '0 24px 60px rgba(0,0,0,.26)',
            }}
          >
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                marginBottom: 18,
                fontFamily: theme.fonts.mono,
                fontSize: 24,
                fontWeight: 900,
              }}
            >
              <span>☀</span>
              <span>{brightness}%</span>
            </div>
            <div
              style={{
                display: 'grid',
                gridTemplateColumns: 'repeat(12, 1fr)',
                gap: 7,
              }}
            >
              {Array.from({length: 12}, (_, index) => (
                <span
                  key={`brightness-bar-${index}`}
                  style={{
                    height: 34,
                    borderRadius: 8,
                    background: index < activeBars ? theme.colors.accent : 'rgba(0,0,0,.16)',
                  }}
                />
              ))}
            </div>
          </div>
        </div>
      </BeatCard>
    </div>
  );
};
