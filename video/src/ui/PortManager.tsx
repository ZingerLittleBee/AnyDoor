import type {FC} from 'react';
import {Easing} from 'remotion';
import type {Bi, Lang} from '../copy';
import {copy, t} from '../copy';
import {clamp} from '../timing';
import {theme} from '../theme';

type PortManagerProps = {
  frame: number;
  lang: Lang;
};

type PortRecord = {
  port: number;
  process: string;
  pid: number;
};

type SidebarItem = {
  label: Bi;
};

const ports: PortRecord[] = [
  {port: 3000, process: 'node', pid: 1024},
  {port: 5173, process: 'vite', pid: 2156},
  {port: 5432, process: 'postgres', pid: 487},
  {port: 6379, process: 'redis-server', pid: 612},
  {port: 8080, process: 'docker', pid: 1893},
  {port: 8088, process: 'nginx', pid: 902},
  {port: 9229, process: 'node', pid: 4421},
  {port: 27017, process: 'mongod', pid: 765},
  {port: 4000, process: 'python3', pid: 3104},
  {port: 7000, process: 'ControlCenter', pid: 665},
  {port: 4500, process: 'rapportd', pid: 412},
  {port: 50000, process: 'python3', pid: 5821},
];

const sidebarItems: SidebarItem[] = [
  {label: {zh: '应用快捷键', en: 'App Shortcuts'}},
  {label: {zh: '端口管理', en: 'Port Manager'}},
  {label: {zh: '窗口布局', en: 'Window Layout'}},
  {label: {zh: 'Hosts 管理', en: 'Hosts Manager'}},
];

const typedSearch = (frame: number) => {
  const text = ':3000';
  const length = Math.max(0, Math.min(text.length, Math.floor(clamp(frame, [20, 42], [0, text.length], Easing.linear))));
  return text.slice(0, length);
};

export const PortManager: FC<PortManagerProps> = ({frame, lang}) => {
  const highlighted = clamp(frame, [52, 68], [0, 1]);
  const confirmationOpacity = clamp(frame, [84, 104], [0, 1]);
  const confirmationExit = frame >= 132 ? clamp(frame, [132, 140], [1, 0]) : 1;
  const ended = frame >= 142;
  const visiblePorts = ports.slice(0, 5);

  return (
    <div
      data-ui="port-manager"
      style={{
        position: 'absolute',
        top: '50%',
        left: '50%',
        width: 1220,
        height: 650,
        display: 'grid',
        gridTemplateColumns: '390px 1fr',
        gap: 24,
        padding: 16,
        borderRadius: 20,
        border: `.5px solid ${theme.colors.lineStrong}`,
        background: 'rgba(12,12,16,.68)',
        color: theme.colors.text,
        fontFamily: theme.fonts.sans,
        boxShadow: theme.shadow.stage,
        transform: 'translate(-50%, -50%)',
      }}
    >
      <aside
        data-ui="port-sidebar"
        style={{
          borderRadius: 14,
          overflow: 'hidden',
          background: theme.gradients.panel,
          border: `.5px solid ${theme.colors.lineStrong}`,
        }}
      >
        <div
          style={{
            height: 56,
            display: 'flex',
            alignItems: 'center',
            padding: '0 20px',
            borderBottom: `1px solid ${theme.colors.line}`,
            fontSize: 19,
            fontWeight: 900,
          }}
        >
          AnyDoor
        </div>
        <div style={{padding: 10, display: 'flex', flexDirection: 'column', gap: 6}}>
          {sidebarItems.map((item, index) => {
            const active = index === 1;
            return (
              <div
                key={item.label.en}
                style={{
                  height: 54,
                  display: 'flex',
                  alignItems: 'center',
                  gap: 12,
                  padding: '0 14px',
                  borderRadius: 12,
                  background: active ? 'rgba(94,155,255,.20)' : 'transparent',
                  color: active ? theme.colors.text : theme.colors.textDim,
                  fontSize: 18,
                  fontWeight: 800,
                }}
              >
                <span
                  style={{
                    width: 24,
                    height: 24,
                    borderRadius: 8,
                    background: active ? theme.colors.accent : 'rgba(255,255,255,.12)',
                  }}
                />
                {t(item.label, lang)}
              </div>
            );
          })}
        </div>
      </aside>

      <section
        data-ui="port-main"
        style={{
          position: 'relative',
          borderRadius: 14,
          overflow: 'hidden',
          background: theme.gradients.panel,
          border: `.5px solid ${theme.colors.lineStrong}`,
        }}
      >
        <div
          data-ui="port-search"
          style={{
            height: 70,
            display: 'flex',
            alignItems: 'center',
            padding: '0 24px',
            gap: 14,
            borderBottom: `1px solid ${theme.colors.line}`,
          }}
        >
          <span style={{color: theme.colors.textDim, fontSize: 24}}>⌕</span>
          <span style={{fontFamily: theme.fonts.mono, fontSize: 30, fontWeight: 900}}>
            {typedSearch(frame)}
            <span style={{color: theme.colors.accent2}}>|</span>
          </span>
        </div>

        <div data-ui="port-list" style={{padding: '12px 14px 0'}}>
          {visiblePorts.map((record) => {
            const isTarget = record.port === 3000;
            return (
              <div
                key={record.port}
                style={{
                  height: 58,
                  display: 'grid',
                  gridTemplateColumns: '100px 1fr 120px 120px',
                  alignItems: 'center',
                  gap: 14,
                  padding: '0 14px',
                  borderRadius: 12,
                  background: isTarget ? `rgba(94,155,255,${0.10 + highlighted * 0.16})` : 'transparent',
                  border: isTarget ? `1px solid rgba(94,155,255,${0.18 + highlighted * 0.36})` : '1px solid transparent',
                  opacity: isTarget && ended ? 0.45 : 1,
                  color: isTarget && ended ? theme.colors.textSoft : theme.colors.text,
                  fontSize: 18,
                  fontWeight: 800,
                }}
              >
                <span
                  style={{
                    display: 'inline-flex',
                    alignItems: 'center',
                    gap: 9,
                    fontFamily: theme.fonts.mono,
                    color: theme.colors.textDim,
                  }}
                >
                  <span
                    style={{
                      width: 9,
                      height: 9,
                      borderRadius: 999,
                      background: isTarget && ended ? theme.colors.red : theme.colors.green,
                    }}
                  />
                  :{record.port}
                </span>
                <span>{record.process}</span>
                <span style={{fontFamily: theme.fonts.mono, color: theme.colors.textDim}}>PID {record.pid}</span>
                <span
                  style={{
                    justifySelf: 'end',
                    color: isTarget ? theme.colors.red : theme.colors.textSoft,
                    fontSize: 16,
                  }}
                >
                  {isTarget ? (ended ? (lang === 'zh' ? '已结束' : 'Ended') : t(copy.ports.confirmButton, lang)) : ''}
                </span>
              </div>
            );
          })}
        </div>

        <div
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            bottom: 0,
            height: 58,
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            padding: '0 24px',
            borderTop: `1px solid ${theme.colors.line}`,
            color: theme.colors.textDim,
            fontSize: 16,
            fontWeight: 700,
          }}
        >
          <span>{lang === 'zh' ? '12 个监听端口' : '12 listening ports'}</span>
          <span>{lang === 'zh' ? 'Return 确认' : 'Return to confirm'}</span>
        </div>

        <div
          data-ui="port-confirmation"
          style={{
            position: 'absolute',
            top: 178,
            left: '50%',
            width: 460,
            padding: 24,
            borderRadius: 18,
            border: `.5px solid ${theme.colors.lineStrong}`,
            background: 'rgba(34,34,40,.94)',
            boxShadow: theme.shadow.panel,
            opacity: confirmationOpacity * confirmationExit,
            transform: `translateX(-50%) translateY(${clamp(frame, [84, 104], [20, 0])}px) scale(${clamp(frame, [84, 104], [0.96, 1])})`,
          }}
        >
          <div style={{fontSize: 28, fontWeight: 900, marginBottom: 10}}>{t(copy.ports.confirmTitle, lang)}</div>
          <div style={{fontSize: 17, lineHeight: 1.45, color: theme.colors.textDim, marginBottom: 24}}>
            {t(copy.ports.confirmMessage, lang)}
          </div>
          <div style={{display: 'flex', justifyContent: 'flex-end', gap: 12}}>
            <button
              style={{
                width: 132,
                height: 44,
                border: `1px solid ${theme.colors.lineStrong}`,
                borderRadius: 12,
                background: 'rgba(255,255,255,.09)',
                color: theme.colors.text,
                fontFamily: theme.fonts.sans,
                fontSize: 16,
                fontWeight: 800,
              }}
            >
              {lang === 'zh' ? '取消' : 'Cancel'}
            </button>
            <button
              style={{
                width: 132,
                height: 44,
                border: '1px solid rgba(255,255,255,.16)',
                borderRadius: 12,
                background: theme.colors.red,
                color: '#fff',
                fontFamily: theme.fonts.sans,
                fontSize: 16,
                fontWeight: 900,
                transform: frame >= 124 && frame < 132 ? 'translateY(2px) scale(.97)' : 'translateY(0) scale(1)',
              }}
            >
              {t(copy.ports.confirmButton, lang)}
            </button>
          </div>
        </div>
      </section>
    </div>
  );
};
