# Landing Page — Hyper Key Section Extension

## Goal

Add a Hyper Key narrative to the existing `HotkeyDemo` section on the marketing
landing page (`landing/`), so visitors see both the original F-key bindings and
the new Hyper Key shortcut layer without restructuring the page.

## Scope

- Touches only `landing/`. No changes to the AnyDoor macOS app.
- Single section affected: `landing/src/components/HotkeyDemo.astro`.
- Data and copy layers updated additively: `landing/src/lib/data.ts`,
  `landing/src/lib/copy.ts`.
- One Hero pill added in `copy.ts` (`hero.pills`).
- No new dependencies, no new global state.

## Approach

`HotkeyDemo.astro` already renders a mac-screen mock above an interactive
keyboard with an auto-cycling demo of `F1–F6 → app`. The Hyper extension adds a
**mode tab** above the keyboard:

- **F-keys** (default) — existing experience, untouched.
- **Hyper Key** — new tab; viewer-only auto-cycle of four `✦{Letter} → payload`
  bindings.

Tabs swap via a `data-mode` attribute on a wrapping container. CSS handles all
visual state changes; JS swaps which auto-cycle is running.

## Architecture

```
HotkeyDemo.astro
├─ <ModeTabs />              <!-- new: 2 tab buttons, data-mode driver -->
├─ <ScreenMock>              <!-- existing menu bar / hint / winwrap / dock -->
│  └─ <HyperToast>           <!-- new: centered action card, hidden by default -->
├─ <Keyboard>                <!-- existing; CSS reacts to [data-mode] -->
│  ├─ row[F1..F12]           <!-- F-row, .is-hint when mode=fkeys -->
│  ├─ row[Q..]
│  ├─ row[A..]               <!-- home row, S/F/L/M become .is-hint when mode=hyper -->
│  ├─ row[Z..]
│  └─ row[⌃ ⌥ ⌘ ⎵ ⌘ ⌥ ←]
│     └─ ⇪                    <!-- highlighted+pulsing when mode=hyper -->
└─ <HintLine>                <!-- existing; copy swaps via [data-mode] -->
```

Mode driver:

```html
<div class="hkstage" data-mode="fkeys">  <!-- default; toggled by JS on tab click -->
```

CSS selectors then key off `[data-mode="hyper"]`:

```css
.hkstage[data-mode="hyper"] .key[data-key="⇪"] { /* purple gradient + pulse */ }
.hkstage[data-mode="fkeys"] .key[data-key="F1"]:where(.is-hint) { /* existing F-key hint */ }
.hkstage[data-mode="hyper"] .key.is-hint-hyper { /* home-row letters S/F/L/M */ }
```

## Components

### ModeTabs

Two pill-shaped buttons in a small flex container, mounted above the keyboard
(below the screen mock). Clicking either sets `data-mode` on `.hkstage` and
triggers JS tab swap. Visual: inactive = ghost border, active = accent fill.

Bilingual labels via `data-i18n-zh`/`data-i18n-en` per existing pattern.

### HyperBadge

Floating glyph that appears center-screen during the `companion press` phase of
the Hyper cycle. Reuses glass-card aesthetic from existing toggle cards.

```html
<div class="hyper-badge">✦S</div>
```

Animation: fade-in + slight Y-axis lift over 200ms; held for ~600ms; fade-out
over 200ms.

### HyperToast

Centered card overlaid on the screen mock when an Action binding fires. Lives
inside `winwrap` so it stacks the same way as `appwin`. Has:

- Top: large monoline SVG icon (lock / mute-off / etc.)
- Middle: bilingual name
- Bottom: bilingual status line ("已锁定", "已静音")

CSS class `.hyper-toast`. Auto-hide handled by the autoplay tick that emits it.

## Data layer

`landing/src/lib/data.ts` gains:

```ts
export type HyperBinding =
  | {
      kind: 'app';
      letter: string;        // 'S' | 'F' (uppercase, single char)
      name: string;          // 'Safari'
      grad: string;          // gradient for app logo
      tag: string;           // 'macOS Web Browser'
    }
  | {
      kind: 'action';
      letter: string;
      name: { zh: string; en: string };
      stateOn: { zh: string; en: string };
      icon: string;          // key into icons.ts
    };

export const hyperBindings: HyperBinding[] = [
  { kind: 'app',    letter: 'S', name: 'Safari', grad: '...', tag: '...' },
  { kind: 'app',    letter: 'F', name: 'Finder', grad: '...', tag: '...' },
  { kind: 'action', letter: 'L', name: { zh: '锁定屏幕', en: 'Lock Screen' },
                                stateOn: { zh: '已锁定', en: 'Locked' }, icon: 'lock' },
  { kind: 'action', letter: 'M', name: { zh: '静音', en: 'Mute' },
                                stateOn: { zh: '已静音', en: 'Muted' }, icon: 'mute' },
];
```

App entries reuse gradients defined in existing `hotkeyApps` to keep visual
language consistent (Safari + Finder gradients already there).

## Copy layer

`landing/src/lib/copy.ts` gains under `demo`:

```ts
modeFkeys:  { zh: 'F 键模式', en: 'F-keys' },
modeHyper:  { zh: 'Hyper Key', en: 'Hyper Key' },
hyperHint:  {
  zh: '按住 ⇪ 再按字母键 — Hyper 把单键变成一整层快捷键',
  en: 'Hold ⇪ then a letter — Hyper turns one key into a whole shortcut layer',
},
hyperHintScreen: {
  zh: '↓ ⇪ + S F L M 触发 Hyper',
  en: '↓ ⇪ + S F L M for Hyper bindings',
},
```

`hero.pills` appended with `'Hyper Key'` (both zh/en); already a flat string
list so no schema change.

Existing F-key copy is untouched.

## Animation timing

Each Hyper binding cycles through five phases, ~3.2s per binding, ~13s for the
full 4-binding loop. Matches the rhythm of the existing F-key autoplay.

| Phase            | Visual                                                   | Duration |
| ---------------- | -------------------------------------------------------- | -------- |
| idle             | ⇪ pulses purple, keyboard static                         | start    |
| trigger press    | ⇪ adds `.is-pressed`                                     | 280ms    |
| companion press  | letter (S/F/L/M) adds `.is-pressed`; `✦Letter` badge in  | 280ms    |
| payload          | App → `appwin` (existing); Action → `.hyper-toast`       | 2400ms   |
| release          | both keys release; payload fades                         | 200ms    |

Implementation: `setInterval` driver dispatches `hyperTick()` which advances an
index pointer and runs the phase chain via `setTimeout`. Single source of
truth — no overlapping ticks — guarded by clearing both timer ids on tab change.

## Tab swap behaviour

- Click on a tab updates `.hkstage[data-mode]`.
- Outgoing tab: `clearInterval(autoTimer)`; clear `appwin`; hide
  `.hyper-toast`; clear any `.is-pressed`.
- 800ms beat for visual settle.
- Incoming tab: start its respective autoplay (`fkeyTick` or `hyperTick`).

F-key tab retains its existing "stop autoTimer on user keystroke / click"
behaviour. Hyper tab does not because it has no interactive press.

## Visual tokens

- Hyper accent gradient: `linear-gradient(135deg, #9d5aff, #5e9bff)`.
- `.hyper-badge`: ~64×32px pill, gradient background, white text, subtle inner
  glow, `backdrop-filter: blur(8px)`.
- `.hyper-toast`: 240×140px glass card, top-aligned icon (32px), name (16px,
  semibold), state line (12px, muted).
- ⇪ key in Hyper mode: border `1px solid rgba(157,90,255,.6)`, box-shadow glow
  `0 0 12px rgba(157,90,255,.4)`, opacity-pulse animation (`opacity 1 ↔ .75`
  every 1.8s).

## Hero pill addition

Single string append in `copy.ts` `hero.pills`:

```ts
zh: [..., 'Hyper Key'],
en: [..., 'Hyper Key'],
```

Renders automatically through the existing Hero pill loop. No layout change.

## Edge cases

- **Reduced motion** (`@media (prefers-reduced-motion: reduce)`): disable ⇪
  pulse and badge slide; phases still advance via setTimeout but instant
  transitions.
- **Narrow viewport (<720px)**: existing demo already scales down; mode tabs
  inherit the same media query. No specific mobile change.
- **Language switch mid-cycle**: Bi text re-renders via `[data-lang]` CSS rule;
  no JS hook needed.
- **Tab clicked during phase**: clear timers + immediate visual reset (no
  partial leak between modes).

## Testing

Manual sanity-check pass only — landing has no test suite. Verify:

- F-keys tab default; pressing F1–F6 still works.
- Switching to Hyper tab: ⇪ glows; 4-binding cycle runs; ✦ badge floats up;
  Safari/Finder render in `appwin`; Lock/Mute render as toast.
- Switching back to F-keys: state cleanly resets.
- Both `zh` and `en` render correctly per `<html data-lang>`.

## Out of scope

- No real Caps Lock detection / keyboard listening on the landing.
- No Hyper-only deep-dive section elsewhere on the page.
- No FAQ entry update (existing FAQ already general enough).
- No icon library extension beyond reusing existing `lock` and `mute` icons.
- No new analytics events.
