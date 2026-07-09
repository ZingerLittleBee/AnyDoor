# Ubiquitous Language

Glossary of domain terms for AnyDoor. Terms here are canonical: code, UI copy
(in Chinese), and documentation should use them consistently.

## Quicklinks

- **Quicklink** (快速入口) — A user-named, searchable entry that opens an
  arbitrary destination: a web URL, an app deeplink, a local file or folder,
  or a search template. Distinct from an **App Shortcut** (which launches an
  app) and from a browser bookmark (which lives in the browser).
- **Link** (链接) — The single template string a Quicklink stores. What kind
  of destination it is (web / deeplink / file / folder / search template) is
  not declared by the user; it is inferred from the string itself when the
  Quicklink is opened.
- **Search Template** (搜索模板) — A Link containing the `{query}` placeholder.
  Opening it requires an **Argument** (参数) — user-supplied text substituted
  for the placeholder. A Quicklink whose Link has no placeholder opens
  directly and takes no Argument.
- **Keyword** (触发词) — An optional short trigger the user assigns to a
  Quicklink, separate from its display name (e.g. `gh` for "GitHub 搜索").
  Unique (case-insensitive) among Quicklinks. Typing the Keyword followed by
  a space and text in the command palette supplies that text as the Argument
  in one step.
- **Open With** (打开方式) — An optional per-Quicklink app override. When
  unset, the destination opens with the system default handler; when the
  chosen app is missing, opening falls back to the system default.

## Image Conversion

- **Image Conversion** (图片格式转换) — Re-encoding an image into a different
  format. Always produces a *new* file; the source is never modified or
  deleted. Not to be confused with **Calculator Conversion**.
- **Calculator Conversion** (换算) — Unit / currency / time-zone conversion
  performed inline in the command palette. Predates Image Conversion; the two
  share no concepts despite the similar English word.
- **Conversion Basket** (待转列表) — The set of pending images shown in the
  Image Conversion window. Images enter via Finder selection echo, drag &
  drop, paste, or the clipboard-history context menu; each can be removed
  individually before converting. One conversion run applies a single target
  format and quality to the whole basket.
- **Target Format Whitelist** (目标格式白名单) — The curated set of target
  formats offered to the user (PNG, JPEG, HEIC, AVIF, TIFF, GIF, BMP, PDF,
  ICO), filtered at runtime by what the system encoder actually supports.
  Formats requiring third-party encoders (e.g. WebP output) are out of scope.
- **Conversion Record** (转换记录) — A history entry describing one completed
  conversion (source, target format, quality, output location). Capped in
  number; the output file itself is not owned by the record and may be
  deleted by the user independently.
