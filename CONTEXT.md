# Ubiquitous Language

Glossary of domain terms for AnyDoor. Terms here are canonical: code, UI copy
(in Chinese), and documentation should use them consistently.

## Plugins

- **Native Plugin** (原生插件) — A first-party feature module the user installs
  or uninstalls as one unit (e.g. Hosts). Its code always ships with the app;
  installing is a state change, never a download. Distinct from a future
  **Script Plugin** (external, user-authored).
- **Core** (内核) — The always-present part of the app that cannot be
  uninstalled: every command and service not claimed by a Native Plugin.
- **Claim** (认领) — The exclusive ownership of a built-in command by a Native
  Plugin or the Core. Every command has exactly one owner.
- **Install** (安装) — Making a Native Plugin exist for the user: its commands,
  settings, and permission prompts appear. An uninstalled plugin is invisible
  everywhere — it contributes no commands, no settings, and requests no
  permissions.
  _Avoid_: 启用 (reserved for per-command visibility).
- **Uninstall** (卸载) — Cancelling a plugin's in-flight work, releasing the
  shared host resources it holds (e.g. unregistering the privileged helper
  when nothing else needs it), and removing all its surfaces, while
  retaining its user data so a reinstall restores it fully. An uninstall
  never mutates user-visible system state and never prompts for
  authorization — active hosts entries stay in effect until a reinstall
  (ADR-0005 addendum 2026-07-17). Uninstalling is transactional: if
  `deactivate` throws, the plugin remains installed — there is no
  half-uninstalled state.
  _Avoid_: 禁用, 停用.

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

- **Image Conversion** (图片格式转换) — Producing a new encoded image file in a
  chosen target format. It may re-encode or perform an eligible lossless
  container rewrite; the source is never modified or deleted. Not to be
  confused with **Calculator Conversion**.
- **Conversion Mode** (转换模式) — The mutually exclusive Quality or Target
  Size configuration applied to one Image Conversion run. Both modes share the
  same Conversion Basket, output flow, and history.
  _Avoid_: Compression Mode.
- **Comparison Workspace** (对比工作区) — The dual-pane area in the Image
  Conversion window that compares the selected image's original with an exact
  result candidate. Its panes share a normalized field of view, and a matching
  Conversion Run may reuse the candidate.
- **Conversion Inspector** (转换检查器) — The persistent right-side panel beside
  the Comparison Workspace that groups configuration, compatibility warnings,
  selected-candidate metrics, and the run action.
- **Conversion Sidebar** (转换侧边栏) — The left-side panel that switches
  between the Conversion Basket and Conversion Record history; its selection
  determines the content shown by the workspace and inspector.
- **Conversion Preflight** (转换预检) — A lightweight compatibility pass over
  the Conversion Basket that separates eligible items from unsupported ones
  without producing output candidates.
- **Conversion Run** (转换运行) — The cancellable batch operation over all
  preflight-compatible basket items. Completed outputs remain valid when the
  run stops, and hiding the window does not end it.
- **Target Size Compression** (目标体积压缩) — Selecting a candidate under a
  user-chosen file-size limit through an eligible lossless rewrite or the
  versioned bounded-search policy. A run succeeds only when the result stays
  within that limit.
  _Avoid_: Image Compression, File Compression.
- **Resize Fallback** (缩小尺寸兜底) — An opt-in Target Size Compression policy
  that permits proportional pixel-dimension reduction when quality adjustment
  alone cannot meet the Per-Output Limit.
- **Quality Floor** (质量下限) — The format-specific lowest encoder quality
  permitted by Target Size Compression at one pixel size; it is a calibrated
  internal policy, not a user setting.
  _Avoid_: Minimum Quality.
- **Pixel Floor** (像素下限) — The internal minimum longest-edge dimension that
  Resize Fallback may produce; it is not user-configurable.
  _Avoid_: Minimum Size.
- **Best-Effort Result** (最小候选) — The smallest result found when Target Size
  Compression cannot meet the Per-Output Limit under the active policy. It is
  retained as a candidate the user may explicitly save or copy; it is never
  written to disk automatically and never counts as target success.
- **Pass-Through Result** (直通结果) — A new output whose compressed image data
  is copied without re-encoding while the Target Size metadata policy is
  applied. It is successful only when that policy can be applied losslessly and
  the rewritten output still satisfies the Per-Output Limit.
- **Display-Critical Metadata** (显示必需元数据) — Image information required to
  render the intended appearance, including orientation, color profiles, and
  supported HDR data. Target Size Compression preserves it where the Lossy
  Target supports it.
- **Display Downgrade** (显示能力降级) — A V1 conversion whose selected target
  cannot preserve source HDR/gain-map content and therefore produces SDR; the
  downgrade is visible and retained in its Conversion Record.
- **Ancillary Metadata** (附加元数据) — Information that is not required to
  render the intended appearance, including GPS, capture-device details,
  embedded thumbnails, and comments. Target Size Compression removes it.
  _Avoid_: Optional Metadata.
- **Transparency Background** (透明背景色) — The explicit solid color used to
  composite source alpha when the selected target cannot encode it.
- **Per-Output Limit** (单文件体积上限) — The file-size limit applied
  independently to every output in a Target Size Compression run; batch items
  share the value but never pool their byte budgets.
- **Lossy Target** (有损目标格式) — An encoder-available JPEG, HEIC, or AVIF
  output whose quality can be varied for Target Size Compression. Target Size
  mode offers only Lossy Targets; other formats remain available in Quality
  mode only.
  _Avoid_: Compressible Format.
- **Multi-Image Source** (多图源文件) — An image container with more than one
  frame or page. Quality mode converts the first image with a visible
  first-frame-only notice and recorded fact; Target Size rejects it and never
  emits a partial first-image result.
- **Calculator Conversion** (换算) — Unit / currency / time-zone conversion
  performed inline in the command palette. Predates Image Conversion; the two
  share no concepts despite the similar English word.
- **Conversion Basket** (待转列表) — The set of pending images shown in the
  Image Conversion window. Images enter via Finder selection echo, drag &
  drop, paste, or the clipboard-history context menu; each can be removed
  individually before converting. One Conversion Run uses one shared
  configuration; only successful items leave the basket afterward.
- **Target Format Whitelist** (目标格式白名单) — The curated set of target
  formats offered to the user (PNG, JPEG, HEIC, AVIF, TIFF, GIF, BMP, PDF,
  ICO), filtered at runtime by what the system encoder actually supports.
  Formats requiring third-party encoders (e.g. WebP output) are out of scope.
- **Conversion Record** (转换记录) — A history entry describing one completed
  Image Conversion output and its user-relevant configuration/outcome. Records
  do not own their files and are created only when an output exists.
