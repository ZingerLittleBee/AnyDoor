// Client-side language state for component <script>s. The pre-paint script in
// index.astro resolves html[data-lang] before first paint; this module reads it
// back, applies changes from the Nav toggle, and notifies scripts that render
// text dynamically (LCD readouts, toasts) so they can re-render.

import {
  LANG_CHANGE_EVENT,
  LANG_STORAGE_KEY,
  type Bi,
  type Lang,
  type LangChangeDetail,
} from './i18n';

export function currentLang(): Lang {
  return document.documentElement.getAttribute('data-lang') === 'en' ? 'en' : 'zh';
}

// Picks the active variant of a bilingual value.
export function pick<T>(value: Bi<T>, lang: Lang = currentLang()): T {
  return value[lang];
}

// Subscribes to language changes; returns an unsubscribe function. The callback
// does not run for the initial language, so call it once yourself if needed.
export function onLangChange(cb: (lang: Lang) => void): () => void {
  const listener = (e: Event) => cb((e as CustomEvent<LangChangeDetail>).detail.lang);
  document.addEventListener(LANG_CHANGE_EVENT, listener);
  return () => document.removeEventListener(LANG_CHANGE_EVENT, listener);
}

// Rewrites attributes rendered with biAttrs() to the given language.
export function applyBiAttrs(lang: Lang = currentLang(), root: ParentNode = document): void {
  root.querySelectorAll<HTMLElement>('[data-bi-attrs]').forEach((el) => {
    try {
      const attrs = JSON.parse(el.dataset.biAttrs ?? '{}') as Record<string, Bi>;
      for (const [name, value] of Object.entries(attrs)) el.setAttribute(name, value[lang]);
    } catch {}
  });
}

// Switches the page language, persists it, and notifies subscribers. Only the
// Nav toggle should call this.
export function setLang(lang: Lang): void {
  const el = document.documentElement;
  el.setAttribute('data-lang', lang);
  el.setAttribute('lang', lang === 'zh' ? 'zh-CN' : 'en');
  try { localStorage.setItem(LANG_STORAGE_KEY, lang); } catch {}
  applyBiAttrs(lang);
  document.dispatchEvent(new CustomEvent<LangChangeDetail>(LANG_CHANGE_EVENT, { detail: { lang } }));
}
