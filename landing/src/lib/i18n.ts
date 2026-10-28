// Shared bilingual primitives. Both languages are rendered into the HTML and
// html[data-lang] + global.css hide the inactive one; see lang-client.ts for
// the runtime side.

export type Lang = 'zh' | 'en';
export type Bi<T = string> = { zh: T; en: T };

// localStorage key read by the pre-paint script in index.astro.
export const LANG_STORAGE_KEY = 'anydoor.lang';

// Dispatched on `document` after the active language changes.
export const LANG_CHANGE_EVENT = 'anydoor:langchange';
export type LangChangeDetail = { lang: Lang };

// Attribute values cannot be hidden with CSS, so bilingual attributes are
// rendered in Chinese (the document default) and carry both variants in
// `data-bi-attrs`; lang-client.ts rewrites them whenever the language resolves
// or changes. Spread the result onto an element:
//   <button {...biAttrs({ 'aria-label': t.closeAria })}>
export function biAttrs(attrs: Record<string, Bi>): Record<string, string> {
  const out: Record<string, string> = { 'data-bi-attrs': JSON.stringify(attrs) };
  for (const [name, value] of Object.entries(attrs)) out[name] = value.zh;
  return out;
}
