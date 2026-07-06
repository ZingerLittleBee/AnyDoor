# Ubiquitous Language

Glossary of domain terms for AnyDoor. Terms here are canonical: code, UI copy
(in Chinese), and documentation should use them consistently.

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
