# Landing Hyper Key Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `HotkeyDemo.astro` with a "Hyper Key" tab that auto-cycles four `✦{Letter}` bindings (2 apps + 2 system actions) alongside the existing F-key demo.

**Architecture:** Add a mode-tab driver above the keyboard. `data-mode="fkeys"|"hyper"` on `.hkstage` swaps which auto-cycle runs and which CSS visuals apply. New data + copy keys flow through existing bilingual rendering. Single component file changes; no new framework primitives.

**Tech Stack:** Astro 5, Tailwind 4, TypeScript, bilingual via `data-i18n-zh`/`data-i18n-en`.

**Verification:** Landing has no test runner. Each task ends with a manual visual check via `bun run dev` (server already runs; reload page). No automated tests.

---

## File map

| File | Action | Purpose |
| --- | --- | --- |
| `landing/src/lib/copy.ts` | Modify | Add tab labels + Hyper hint strings; add `'Hyper Key'` to hero pills |
| `landing/src/lib/data.ts` | Modify | Add `HyperBinding` type + `hyperBindings` array |
| `landing/src/components/HotkeyDemo.astro` | Modify | Add mode tabs, Hyper tick driver, ✦ badge + toast markup |
| `landing/src/styles/global.css` | Modify | Add `.mode-tabs`, `.hyper-badge`, `.hyper-toast`, `[data-mode="hyper"]` selectors, ⇪ pulse |

No new files.

---

## Task 1: Add copy strings

**Files:**
- Modify: `landing/src/lib/copy.ts`

- [ ] **Step 1: Add `modeFkeys`, `modeHyper`, `hyperHint`, `hyperHintScreen` to `copy.demo`**

Open `landing/src/lib/copy.ts`. Find the `demo: { ... }` block. Add these keys at the end of the demo object (just before its closing `}`):

```ts
modeFkeys: { zh: 'F 键模式', en: 'F-keys' },
modeHyper: { zh: 'Hyper Key', en: 'Hyper Key' },
hyperHint: {
  zh: '按住 ⇪ 再按字母键 — Hyper 把单键变成一整层快捷键',
  en: 'Hold ⇪ then a letter — Hyper turns one key into a whole shortcut layer',
},
hyperHintScreen: {
  zh: '↓ ⇪ + S F L M 触发 Hyper',
  en: '↓ ⇪ + S F L M for Hyper bindings',
},
```

- [ ] **Step 2: Append "Hyper Key" to `hero.pills`**

Find the `hero.pills` block:

```ts
pills: {
  zh: ['全局热键', '端口管理', '深色模式', '屏幕 OCR', '取色器', '识别二维码', 'Liquid Glass'],
  en: ['Global hotkeys', 'Port manager', 'Dark mode', 'Screen OCR', 'Color picker', 'QR scan', 'Liquid Glass'],
},
```

Change both arrays to append `'Hyper Key'`:

```ts
pills: {
  zh: ['全局热键', '端口管理', '深色模式', '屏幕 OCR', '取色器', '识别二维码', 'Liquid Glass', 'Hyper Key'],
  en: ['Global hotkeys', 'Port manager', 'Dark mode', 'Screen OCR', 'Color picker', 'QR scan', 'Liquid Glass', 'Hyper Key'],
},
```

- [ ] **Step 3: Verify by reloading the landing page**

Run: `cd landing && bun run dev` (skip if already running). Open `http://localhost:4321` in browser. Confirm the Hero pills row now includes "Hyper Key" / "Hyper Key" at the end.

Expected: New pill visible; no console errors; no layout shift.

- [ ] **Step 4: Commit**

```bash
git add landing/src/lib/copy.ts
git commit -m "feat(landing): add Hyper Key copy strings and hero pill"
```

---

## Task 2: Add HyperBinding data layer

**Files:**
- Modify: `landing/src/lib/data.ts`

- [ ] **Step 1: Add `HyperBinding` type and `hyperBindings` array at end of file**

Open `landing/src/lib/data.ts`. After the existing `hotkeyApps` block, add:

```ts
// Hyper Key tab — letter triggers mixing apps and system actions.
export type HyperBinding =
  | {
      kind: 'app';
      letter: string;
      name: string;
      grad: string;
      tag: string;
    }
  | {
      kind: 'action';
      letter: string;
      name: Bi;
      stateOn: Bi;
      icon: string;
    };

export const hyperBindings: HyperBinding[] = [
  {
    kind: 'app',
    letter: 'S',
    name: 'Safari',
    grad: 'linear-gradient(135deg, #36d4ff, #1873e8)',
    tag: 'macOS Web Browser',
  },
  {
    kind: 'app',
    letter: 'F',
    name: 'Finder',
    grad: 'linear-gradient(135deg, #6dd4ff, #1f8fff)',
    tag: 'macOS File Browser',
  },
  {
    kind: 'action',
    letter: 'L',
    name: { zh: '锁定屏幕', en: 'Lock Screen' },
    stateOn: { zh: '已锁定', en: 'Locked' },
    icon: 'lock',
  },
  {
    kind: 'action',
    letter: 'M',
    name: { zh: '静音', en: 'Mute' },
    stateOn: { zh: '已静音', en: 'Muted' },
    icon: 'mute',
  },
];
```

- [ ] **Step 2: Verify TypeScript compiles**

Run: `cd landing && bun run astro check 2>&1 | tail -10`

Expected: 0 errors (warnings ok). If `astro check` is not configured, run `bun run build` and confirm no type errors.

- [ ] **Step 3: Commit**

```bash
git add landing/src/lib/data.ts
git commit -m "feat(landing): add HyperBinding type and hyperBindings table"
```

---

## Task 3: Add mode tabs markup + initial `data-mode` driver

**Files:**
- Modify: `landing/src/components/HotkeyDemo.astro`

- [ ] **Step 1: Add `data-mode="fkeys"` to `.hkstage`**

Find the line:

```astro
  <div class="hkstage">
```

(Around line 35 of `HotkeyDemo.astro`.) Change it to:

```astro
  <div class="hkstage" data-mode="fkeys">
```

- [ ] **Step 2: Insert mode-tabs markup below the lede paragraph and before `.hkstage`**

Locate the existing `<p class="lede">...</p>` block followed by `<div class="hkstage" data-mode="fkeys">`. Insert this tab UI **inside `.hkstage`, as its first child** (before `.hkscreen`):

```astro
    <div class="mode-tabs" role="tablist">
      <button class="mode-tab is-active" data-tab="fkeys" type="button" aria-selected="true">
        <span data-i18n-zh>{copy.demo.modeFkeys.zh}</span><span data-i18n-en>{copy.demo.modeFkeys.en}</span>
      </button>
      <button class="mode-tab" data-tab="hyper" type="button" aria-selected="false">
        <span class="hyper-glyph">✦</span>
        <span data-i18n-zh>{copy.demo.modeHyper.zh}</span><span data-i18n-en>{copy.demo.modeHyper.en}</span>
      </button>
    </div>
```

- [ ] **Step 3: Add CSS for `.mode-tabs` to `landing/src/styles/global.css`**

Append to the end of the "Hotkey demo" section (just before `/* ─────────────────────────── Toggle cards ─────────────────────────── */` at line 423):

```css
/* Mode tabs */
.mode-tabs{
  display:inline-flex; gap:4px; padding:4px;
  background: rgba(28,28,32,.55);
  border: .5px solid var(--color-line);
  border-radius: 10px;
  margin-bottom: 6px;
}
.mode-tab{
  display:inline-flex; align-items:center; gap:6px;
  padding: 6px 14px;
  background: transparent; border: none;
  border-radius: 7px;
  color: var(--color-text-soft);
  font: 500 12px/1 var(--font-sans, system-ui);
  cursor: pointer;
  transition: background .15s, color .15s;
}
.mode-tab:hover{color: var(--color-text)}
.mode-tab.is-active{
  background: linear-gradient(135deg, rgba(157,90,255,.25), rgba(94,155,255,.25));
  color: #fff;
  box-shadow: inset 0 0 0 .5px rgba(157,90,255,.4);
}
.mode-tab .hyper-glyph{
  background: linear-gradient(135deg, #9d5aff, #5e9bff);
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
  font-weight: 700;
}
```

- [ ] **Step 4: Verify tabs render**

Reload `http://localhost:4321` in browser. Scroll to the Hotkey Demo section.

Expected: Two pill tabs above the keyboard/screen. "F-keys" is active (gradient bg). "Hyper Key" is inactive with a colorful ✦ glyph. Clicking does nothing yet (JS not wired). No layout regressions.

- [ ] **Step 5: Commit**

```bash
git add landing/src/components/HotkeyDemo.astro landing/src/styles/global.css
git commit -m "feat(landing): render mode tabs above hotkey demo"
```

---

## Task 4: Wire up tab click → swap `data-mode`

**Files:**
- Modify: `landing/src/components/HotkeyDemo.astro`

- [ ] **Step 1: Add tab click handler inside the existing `<script>` block**

Find the existing `<script>` tag in `HotkeyDemo.astro` (starts around line 103). At the top of the script body (just after the imports / element grabs, before `let openApp`), capture the stage element:

```ts
  const stage = document.querySelector<HTMLElement>('.hkstage')!;
```

At the end of the script body (after the existing `autoTimer = window.setInterval(tick, 4600)`), append:

```ts
  // Mode tabs
  const tabs = document.querySelectorAll<HTMLButtonElement>('.mode-tab');
  tabs.forEach((btn) => {
    btn.addEventListener('click', () => {
      const next = btn.dataset.tab as 'fkeys' | 'hyper';
      if (stage.dataset.mode === next) return;
      tabs.forEach((t) => {
        const active = t.dataset.tab === next;
        t.classList.toggle('is-active', active);
        t.setAttribute('aria-selected', String(active));
      });
      stage.dataset.mode = next;
    });
  });
```

- [ ] **Step 2: Verify tab swap visually**

Reload `http://localhost:4321`. Click "Hyper Key" tab.

Expected: Active state moves to Hyper tab. `.hkstage` `data-mode` attribute (check via devtools) becomes `"hyper"`. Click "F-keys" again — reverts.

(No visual change inside the demo yet — that comes with later CSS rules.)

- [ ] **Step 3: Commit**

```bash
git add landing/src/components/HotkeyDemo.astro
git commit -m "feat(landing): swap data-mode on hotkey demo tab click"
```

---

## Task 5: Add Hyper-mode CSS visuals (⇪ glow, home row hints, F-row dim)

**Files:**
- Modify: `landing/src/styles/global.css`
- Modify: `landing/src/components/HotkeyDemo.astro`

- [ ] **Step 1: Tag home row letters with `data-hyper-key` in the keyboard markup**

In `HotkeyDemo.astro`, find the row mapping:

```astro
        {[row1, row2, row3, row4].map((r, ri) => (
          <div class="kbrow">
            {r.map((k) => (
              <div class="key" data-key={k} style={`min-width: ${keyWidth(k, ri + 1)}px`}>{k}</div>
            ))}
          </div>
        ))}
```

Replace the inner `<div class="key">` with one that adds a `data-hyper-key` flag for the S/F/L/M letters:

```astro
        {[row1, row2, row3, row4].map((r, ri) => (
          <div class="kbrow">
            {r.map((k) => {
              const isHyper = ['S', 'F', 'L', 'M'].includes(k);
              return (
                <div
                  class="key"
                  data-key={k}
                  data-hyper-key={isHyper ? '' : undefined}
                  style={`min-width: ${keyWidth(k, ri + 1)}px`}
                >{k}</div>
              );
            })}
          </div>
        ))}
```

- [ ] **Step 2: Append Hyper-mode CSS rules to `global.css`**

Append to the end of the Keyboard CSS block (just before the `/* ─────────────────────────── Toggle cards ─────────────────────────── */` marker; you added `.mode-tabs` here in Task 3, so add this right after `.mode-tab .hyper-glyph`):

```css
/* Hyper mode keyboard visuals */
@keyframes hyperPulse {
  0%, 100% { opacity: 1; }
  50%      { opacity: .65; }
}
.hkstage[data-mode="hyper"] .key[data-key="⇪"]{
  background: linear-gradient(180deg, #6a3acc, #3a1f80);
  border-color: rgba(157,90,255,.6);
  box-shadow: 0 0 0 .5px rgba(157,90,255,.5), 0 0 22px rgba(157,90,255,.45);
  color: #fff;
  animation: hyperPulse 1.8s ease-in-out infinite;
}
.hkstage[data-mode="hyper"] .key.is-hint{
  /* Suppress the existing blue F-key hint while in Hyper mode. */
  box-shadow: none;
  border-color: var(--color-line-strong);
}
.hkstage[data-mode="hyper"] .key[data-hyper-key]{
  box-shadow: 0 0 0 .5px rgba(157,90,255,.5), 0 0 22px rgba(157,90,255,.4);
  border-color: rgba(157,90,255,.5);
}
.hkstage[data-mode="hyper"] .key[data-key="⇪"].is-pressed,
.hkstage[data-mode="hyper"] .key[data-hyper-key].is-pressed{
  background: linear-gradient(135deg, #9d5aff, #5e9bff);
  border-color: #b07eff;
  box-shadow: 0 0 28px rgba(157,90,255,.7);
}
@media (prefers-reduced-motion: reduce) {
  .hkstage[data-mode="hyper"] .key[data-key="⇪"]{ animation: none; }
}
```

- [ ] **Step 3: Verify visuals**

Reload `http://localhost:4321`. Click "Hyper Key" tab.

Expected:
- ⇪ glows purple and pulses
- S / F / L / M keys glow purple
- F1–F6 no longer have the blue hint glow
- Click "F-keys" tab → reverts (F1–F6 glow blue, ⇪ normal)

- [ ] **Step 4: Commit**

```bash
git add landing/src/styles/global.css landing/src/components/HotkeyDemo.astro
git commit -m "feat(landing): style ⇪ + home-row letters for Hyper mode"
```

---

## Task 6: Add ✦ badge and Hyper toast markup + CSS

**Files:**
- Modify: `landing/src/components/HotkeyDemo.astro`
- Modify: `landing/src/styles/global.css`

- [ ] **Step 1: Add badge + toast containers inside `.hkscreen`**

In `HotkeyDemo.astro`, locate the `<div class="winwrap" id="hkscreen-winwrap" />` line. Replace it with:

```astro
      <div class="winwrap" id="hkscreen-winwrap">
        <div class="hyper-badge" id="hyper-badge" aria-hidden="true"></div>
        <div class="hyper-toast" id="hyper-toast" aria-hidden="true"></div>
      </div>
```

- [ ] **Step 2: Append badge + toast CSS**

Append to `global.css` after the Hyper-mode keyboard block:

```css
/* Hyper badge — appears center-screen on companion key press */
.hyper-badge{
  position: absolute;
  top: 38%; left: 50%; transform: translate(-50%, 0);
  padding: 6px 14px;
  font: 700 18px/1 var(--font-mono);
  color: #fff;
  background: linear-gradient(135deg, rgba(157,90,255,.85), rgba(94,155,255,.85));
  border-radius: 10px;
  box-shadow: 0 0 24px rgba(157,90,255,.55);
  backdrop-filter: blur(8px);
  opacity: 0; pointer-events: none;
  transition: opacity .2s ease, transform .2s ease;
  z-index: 5;
}
.hyper-badge.show{
  opacity: 1; transform: translate(-50%, -10px);
}
@media (prefers-reduced-motion: reduce) {
  .hyper-badge{ transition: opacity .2s ease; }
  .hyper-badge.show{ transform: translate(-50%, 0); }
}

/* Hyper toast — payload for action bindings */
.hyper-toast{
  position: absolute;
  top: 50%; left: 50%; transform: translate(-50%, -50%);
  width: 240px; padding: 22px 18px;
  display: none; flex-direction: column; align-items: center; gap: 8px;
  background: rgba(28,28,32,.85);
  border: .5px solid var(--color-line-strong);
  border-radius: 16px;
  box-shadow: 0 12px 48px rgba(0,0,0,.45);
  backdrop-filter: blur(12px);
  z-index: 4;
}
.hyper-toast.show{ display: flex; }
.hyper-toast .ico{
  width: 44px; height: 44px; border-radius: 12px;
  background: linear-gradient(135deg, rgba(157,90,255,.25), rgba(94,155,255,.2));
  color: #b07eff;
  display: grid; place-items: center;
}
.hyper-toast .ico svg{ width: 24px; height: 24px; stroke: currentColor; fill: none; stroke-width: 2; }
.hyper-toast .name{ font: 600 16px/1.2 var(--font-sans, system-ui); color: var(--color-text); text-align:center; }
.hyper-toast .state{ font: 500 12px/1.2 var(--font-mono); color: var(--color-text-soft); }
```

- [ ] **Step 3: Verify badge + toast are present but hidden**

Reload `http://localhost:4321`. Inspect DOM: `#hyper-badge` and `#hyper-toast` should exist inside `.winwrap`. Both should be invisible (opacity 0 / display none).

Expected: No visible regression. Devtools shows the new elements.

- [ ] **Step 4: Commit**

```bash
git add landing/src/components/HotkeyDemo.astro landing/src/styles/global.css
git commit -m "feat(landing): add Hyper badge + toast skeleton elements"
```

---

## Task 7: Implement Hyper autoplay cycle

**Files:**
- Modify: `landing/src/components/HotkeyDemo.astro`

- [ ] **Step 1: Import `hyperBindings` + `icons` and grab badge/toast elements**

In the existing `<script>` block at the top, find:

```ts
  import { hotkeyApps } from '../lib/data';
```

Replace with:

```ts
  import { hotkeyApps, hyperBindings, type HyperBinding } from '../lib/data';
  import { icons } from '../lib/icons';
```

Below the existing element grabs (`screen`, `winwrap`, `appNameEl`, and the new `stage` from Task 4), add:

```ts
  const badge = document.getElementById('hyper-badge')!;
  const toast = document.getElementById('hyper-toast')!;
```

- [ ] **Step 2: Add Hyper tick driver + helpers at end of script (just before mode-tabs handler from Task 4)**

Append (keeping mode-tabs handler **after** this block — reorder if needed):

```ts
  // ─── Hyper tab autoplay ──────────────────────────────────────────
  let hyperTimer: number | undefined;
  let hyperIdx = 0;
  let hyperPhase: number[] = [];

  const clearHyperPhase = () => {
    hyperPhase.forEach((id) => window.clearTimeout(id));
    hyperPhase = [];
  };

  const releaseHyperKeys = () => {
    document.querySelectorAll<HTMLElement>('.hkstage[data-mode="hyper"] .key.is-pressed')
      .forEach((el) => el.classList.remove('is-pressed'));
    badge.classList.remove('show');
    badge.textContent = '';
    toast.classList.remove('show');
    toast.innerHTML = '';
    renderApp(null);
  };

  const renderHyperPayload = (b: HyperBinding) => {
    if (b.kind === 'app') {
      renderApp({
        key: '',
        name: b.name,
        grad: b.grad,
        letter: b.letter,
        tag: b.tag,
      });
    } else {
      const iconSvg = (icons as Record<string, () => string>)[b.icon]?.() ?? '';
      toast.innerHTML = `
        <div class="ico">${iconSvg}</div>
        <div class="name">
          <span data-i18n-zh>${b.name.zh}</span><span data-i18n-en>${b.name.en}</span>
        </div>
        <div class="state">
          <span data-i18n-zh>${b.stateOn.zh}</span><span data-i18n-en>${b.stateOn.en}</span>
        </div>`;
      toast.classList.add('show');
    }
  };

  const hyperTick = () => {
    clearHyperPhase();
    releaseHyperKeys();
    const b = hyperBindings[hyperIdx % hyperBindings.length];
    hyperIdx++;

    const caps = document.querySelector<HTMLElement>('.key[data-key="⇪"]')!;
    const letter = document.querySelector<HTMLElement>(`.key[data-key="${b.letter}"]`)!;

    // Phase 1: trigger press (⇪ goes down)
    hyperPhase.push(window.setTimeout(() => {
      caps.classList.add('is-pressed');
    }, 0));

    // Phase 2: companion press + badge in
    hyperPhase.push(window.setTimeout(() => {
      letter.classList.add('is-pressed');
      badge.textContent = `✦${b.letter}`;
      badge.classList.add('show');
    }, 280));

    // Phase 3: payload
    hyperPhase.push(window.setTimeout(() => {
      renderHyperPayload(b);
    }, 560));

    // Phase 4: release keys (badge stays for a beat with payload)
    hyperPhase.push(window.setTimeout(() => {
      caps.classList.remove('is-pressed');
      letter.classList.remove('is-pressed');
      badge.classList.remove('show');
    }, 1100));

    // Phase 5: clear payload before next tick
    hyperPhase.push(window.setTimeout(() => {
      toast.classList.remove('show');
      renderApp(null);
    }, 3000));
  };
```

- [ ] **Step 3: Update the mode-tabs handler to start/stop autoplay per tab**

Replace the mode-tabs handler block (added in Task 4) with:

```ts
  // Mode tabs
  const tabs = document.querySelectorAll<HTMLButtonElement>('.mode-tab');
  const stopFkeys = () => {
    if (autoTimer) { window.clearInterval(autoTimer); autoTimer = undefined; }
    clearTimeout(pressTimer);
    document.querySelectorAll<HTMLElement>('.key.is-pressed').forEach((el) => el.classList.remove('is-pressed'));
    renderApp(null);
  };
  const stopHyper = () => {
    if (hyperTimer) { window.clearInterval(hyperTimer); hyperTimer = undefined; }
    clearHyperPhase();
    releaseHyperKeys();
  };
  const startFkeys = () => {
    autoTimer = window.setInterval(tick, 4600);
    window.setTimeout(tick, 800);
  };
  const startHyper = () => {
    hyperIdx = 0;
    hyperTimer = window.setInterval(hyperTick, 3400);
    window.setTimeout(hyperTick, 800);
  };

  tabs.forEach((btn) => {
    btn.addEventListener('click', () => {
      const next = btn.dataset.tab as 'fkeys' | 'hyper';
      if (stage.dataset.mode === next) return;
      tabs.forEach((t) => {
        const active = t.dataset.tab === next;
        t.classList.toggle('is-active', active);
        t.setAttribute('aria-selected', String(active));
      });
      stage.dataset.mode = next;
      if (next === 'hyper') { stopFkeys(); startHyper(); }
      else                  { stopHyper();  startFkeys(); }
    });
  });
```

Also: change the existing F-key kick-off so it can be re-started cleanly. Find:

```ts
  autoTimer = window.setInterval(tick, 4600);
  setTimeout(tick, 1500);
```

Leave it as-is (initial F-key autoplay still runs on page load via the existing two lines). The new handler calls `startFkeys()` only when re-entering the F-key tab.

- [ ] **Step 4: Verify Hyper cycle runs**

Reload `http://localhost:4321`. Click "Hyper Key" tab.

Expected:
- After ~800ms, ⇪ presses down (purple highlight)
- ~280ms later, `S` highlights and `✦S` badge floats up
- ~560ms later, Safari window appears
- ~1.1s after start, keys release; badge fades
- ~3s after start, Safari closes
- Next cycle starts (Finder), then Lock toast, then Mute toast, then loops

Click "F-keys" tab — should cleanly stop Hyper cycle and resume F-key cycle.

- [ ] **Step 5: Commit**

```bash
git add landing/src/components/HotkeyDemo.astro
git commit -m "feat(landing): autoplay Hyper Key bindings on tab activation"
```

---

## Task 8: Swap hint text per mode

**Files:**
- Modify: `landing/src/components/HotkeyDemo.astro`
- Modify: `landing/src/styles/global.css`

- [ ] **Step 1: Add Hyper hint markup alongside the existing F-key hint**

Find the existing `<div class="hkscreen-hint">` block:

```astro
      <div class="hkscreen-hint">
        <span data-i18n-zh>{copy.demo.hintScreen.zh}</span><span data-i18n-en>{copy.demo.hintScreen.en}</span>
      </div>
```

Replace with:

```astro
      <div class="hkscreen-hint hint-fkeys">
        <span data-i18n-zh>{copy.demo.hintScreen.zh}</span><span data-i18n-en>{copy.demo.hintScreen.en}</span>
      </div>
      <div class="hkscreen-hint hint-hyper">
        <span data-i18n-zh>{copy.demo.hyperHintScreen.zh}</span><span data-i18n-en>{copy.demo.hyperHintScreen.en}</span>
      </div>
```

Find the existing bottom hint line (`<div class="hint-line">` near the end):

```astro
      <div class="hint-line">
        <b><span data-i18n-zh>{copy.demo.hint.zh}</span><span data-i18n-en>{copy.demo.hint.en}</span></b>
        <span data-i18n-zh>{copy.demo.hintAfter.zh}</span><span data-i18n-en>{copy.demo.hintAfter.en}</span>
      </div>
```

Replace with:

```astro
      <div class="hint-line hint-fkeys">
        <b><span data-i18n-zh>{copy.demo.hint.zh}</span><span data-i18n-en>{copy.demo.hint.en}</span></b>
        <span data-i18n-zh>{copy.demo.hintAfter.zh}</span><span data-i18n-en>{copy.demo.hintAfter.en}</span>
      </div>
      <div class="hint-line hint-hyper">
        <span data-i18n-zh>{copy.demo.hyperHint.zh}</span><span data-i18n-en>{copy.demo.hyperHint.en}</span>
      </div>
```

- [ ] **Step 2: Add CSS rules to show/hide hints per mode**

Append to `global.css` (within the Hotkey demo section, after the Hyper toast styles):

```css
/* Hint visibility per mode */
.hkstage[data-mode="fkeys"] .hint-hyper{ display: none; }
.hkstage[data-mode="hyper"] .hint-fkeys{ display: none; }
```

- [ ] **Step 3: Verify hint swap**

Reload `http://localhost:4321`.

Expected:
- F-keys tab: screen shows "↓ 按 F1 – F6 启动应用" / bottom shows "试试按 F1 – F6 — 也可以试按 Esc 关闭。"
- Hyper tab: screen shows "↓ ⇪ + S F L M 触发 Hyper" / bottom shows "按住 ⇪ 再按字母键 — Hyper 把单键变成一整层快捷键"
- Switching tabs swaps both hints atomically.

- [ ] **Step 4: Commit**

```bash
git add landing/src/components/HotkeyDemo.astro landing/src/styles/global.css
git commit -m "feat(landing): swap hint text between F-keys and Hyper modes"
```

---

## Task 9: Final visual pass and language toggle sanity check

**Files:**
- None (verification only)

- [ ] **Step 1: Full demo pass in zh**

Open `http://localhost:4321` with `<html data-lang="zh">` (default). Scroll to Hotkey Demo. Let F-key autoplay run for ~10s, switch to Hyper tab, let Hyper autoplay run for one full cycle (~13s).

Confirm:
- Hero pills include "Hyper Key" as the last pill
- F-key tab cycles F1–F6 → apps (Dockerman / ServerBee / Finder / Safari / Notes / Calculator)
- Hyper tab cycles ✦S → Safari, ✦F → Finder, ✦L → 锁定屏幕 toast, ✦M → 静音 toast
- No flicker between tabs; previous payload always clears
- ⇪ purple pulse runs continuously in Hyper mode

- [ ] **Step 2: Same pass in en**

Use devtools to set `<html data-lang="en">` (or temporarily change the index.astro `<html lang="zh-CN" data-lang="zh">` to `data-lang="en"` and reload).

Confirm:
- Tab labels read "F-keys" / "Hyper Key"
- Hyper hint reads "Hold ⇪ then a letter — Hyper turns one key into a whole shortcut layer"
- Toast labels read "Locked" / "Muted"

Revert the lang change if you modified the source.

- [ ] **Step 3: Reduced-motion check**

In macOS System Settings → Accessibility → Display → enable "Reduce motion". Reload page. In Hyper mode the ⇪ pulse should stop animating; badge slide-up becomes static fade.

- [ ] **Step 4: Build sanity**

Run: `cd landing && bun run build 2>&1 | tail -10`

Expected: Build succeeds. No type errors. No broken imports.

- [ ] **Step 5: Commit (only if any tweaks were made during the pass)**

If you made any minor copy/spacing fixes during this pass:

```bash
git add -A
git commit -m "chore(landing): polish Hyper Key tab visuals"
```

If nothing changed, skip the commit.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
| --- | --- |
| Goal / Scope | Tasks 1–8 |
| Component diagram (ModeTabs, HyperBadge, HyperToast) | Tasks 3, 6 |
| Data layer (`HyperBinding`, `hyperBindings`) | Task 2 |
| Copy layer (`modeFkeys`, `modeHyper`, `hyperHint`, `hyperHintScreen`, hero pill) | Task 1, Task 8 |
| Animation timing | Task 7 |
| Tab swap behaviour | Task 7 (stop/start helpers) |
| Visual tokens (purple gradient, glow, ⇪ pulse, badge, toast) | Tasks 3, 5, 6 |
| Edge cases (reduced motion, narrow viewport, language switch) | Tasks 5, 6, 9 |
| Testing (manual reload pass) | Task 9 |

All covered. No gaps.

**Type/name consistency:**
- `HyperBinding` defined in Task 2, referenced in Task 7. ✓
- `hyperBindings` defined in Task 2, imported in Task 7. ✓
- `copy.demo.modeFkeys` / `modeHyper` / `hyperHint` / `hyperHintScreen` consistent across Task 1 and Task 8. ✓
- `data-mode`, `data-tab`, `data-hyper-key` attribute names consistent across Tasks 3, 4, 5, 7.

**Placeholders:** None.
