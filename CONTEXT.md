# Ubiquitous Language

Glossary of domain terms for AnyDoor. Terms here are canonical: code, UI copy
(in Chinese), and documentation should use them consistently.

## Plugins

- **Native Plugin** (原生插件) — A first-party feature module the user installs
  or uninstalls as one unit (e.g. Hosts). Its code always ships with the app;
  installing is a state change, never a download. Distinct from a
  **Script Plugin**.
- **Script Plugin** (脚本插件) — A plugin authored outside the app and
  installed as a package the user obtains separately; its code does not ship
  with the app. It acts only through the Capabilities it is granted. Distinct
  from a Native Plugin.
- **Capability** (能力) — A host facility a Script Plugin must declare to use
  (e.g. network access, its private storage). A Capability that is not
  granted does not exist for the plugin.
- **Core** (内核) — The always-present part of the app that cannot be
  uninstalled: every command and service not claimed by a Native Plugin.
- **Claim** (认领) — The exclusive ownership of a built-in command by a Native
  Plugin or the Core. Every command has exactly one owner.
- **Install** (安装) — Making a plugin exist for the user: its commands,
  settings, and permission prompts appear. For a Native Plugin this is a
  state change, never a download; for a Script Plugin it brings the plugin's
  package into the app. An uninstalled plugin is invisible everywhere — it
  contributes no commands, no settings, and requests no permissions.
  _Avoid_: 启用 (reserved for per-command visibility).
- **Uninstall** (卸载) — Removing all of a plugin's surfaces while retaining
  its user data, so a reinstall restores it fully. For a Native Plugin this
  cancels in-flight work and releases the shared host resources it holds
  (e.g. unregistering the privileged helper when nothing else needs it); it
  never mutates user-visible system state and never prompts for
  authorization — active hosts entries stay in effect until a reinstall
  (ADR-0005 addendum 2026-07-17) — and it is transactional: if `deactivate`
  throws, the plugin remains installed; there is no half-uninstalled state.
  For a Script Plugin it removes the installed package while retaining the
  plugin's private storage.
  _Avoid_: 禁用, 停用.
- **Sideload** (旁加载) — Installing a Script Plugin from a local package the
  user picked themselves, rather than from a store.
- **Dev Plugin** (开发插件) — A Script Plugin loaded in place from a local
  development directory, so changes take effect without reinstalling. Only
  available in developer mode; never copied into the app.
  _Avoid_: 链接 (reserved for Quicklinks).

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

## Clipboard History

- **Clipboard History Access** (剪贴板历史访问) — Clipboard capture, indexed
  search, every Retention Period including Unlimited, favorites, tags, OCR, QR
  indexing, encryption, and every history action are available to all AnyDoor
  users. The domain has no Pro user, subscription, entitlement, account, or
  feature gate.
  _Avoid_: Clipboard Pro, Free Limit, Retention Entitlement.
- **Clipboard History Module** (剪贴板历史模块) — The deep
  `ClipboardHistory` package target whose concrete instance hides passive
  capture, canonicalization, persistence, encryption, search, retention,
  migration, derived indexing, and maintenance behind typed capture, query,
  mutation, materialization, and status operations. SwiftUI, focus restoration,
  synthetic paste, localization, and plugin presentation remain in the host.
  Callers never see GRDB records, SQL, Keychain handles, or encrypted payload
  URLs, and the app does not retain a mutable global history-store singleton.
  _Avoid_: Clipboard Repository Protocol, Clipboard Store Singleton, Database Service.
- **Clipboard History Store** (剪贴板历史存储) — The device-local persistence
  boundary formed by one dedicated SQLite database and its sibling payload
  directory at
  `~/Library/Application Support/dev.bybee.AnyDoor/ClipboardHistory/`, accessed
  through GRDB with SQLCipher. SQLCipher encrypts the database, search index,
  and write-ahead log; CryptoKit AES-GCM encrypts owned payload and thumbnail
  files. A device-only master key lives in Keychain, with no user password or
  encryption toggle. The store is the sole source of truth for history entries
  and search state, is not part of the shared SwiftData `ModelContainer`, and
  remains outside Config Sync and Config Backup. Those portability features
  carry tag definitions, tag order, and excluded-source rules, but not
  device-local history membership, monitoring, copy-only behavior, Retention
  Period, or Automatic Image Text Indexing; restoring them never enables
  monitoring or replaces or merges local history.
  _Avoid_: Clipboard ModelContainer, Shared App Store.
- **Store Unavailable** (存储不可用) — A Clipboard History state in which its
  Keychain key is missing or the SQLCipher database cannot be opened or pass
  integrity validation.
  Capture and derived indexing stop without creating a replacement store.
  Retry is non-destructive; the only recovery that deletes unreadable history
  is an explicitly confirmed Reset Clipboard History action, which removes the
  old store and key before generating a new one. A merely locked Keychain is a
  transient pause that resumes after unlock without showing a permanent error.
  _Avoid_: Empty History, Automatic Reset, Encryption Disabled.
- **Clipboard Entry** (剪贴板记录) — The one history record produced by one
  eligible observed general-pasteboard state or one explicit AnyDoor
  clipboard-producing action. It owns an ordered collection of one or more
  Clipboard Items and is the unit of recency, duplicate reuse, search,
  retention, favorite state, tags, and deletion. One copy operation never
  splits into sibling history records.
  _Avoid_: Clipboard Event, Clipboard Item, History Group.
- **Clipboard Item** (剪贴板项目) — One ordered `NSPasteboardItem` preserved
  inside a Clipboard Entry, with its own Standard Clipboard Representations.
  Item boundaries are never flattened by `NSPasteboard.string(forType:)` or by
  choosing files, images, or text through a type-priority branch. Normal paste
  reconstructs every item in its original order. The Capture Safety Limit
  applies to the complete Entry rather than independently to each Item.
  _Avoid_: History Entry, Joined Text, Primary Format.
- **Encrypted Payload Publication** (加密载荷发布) — The crash-consistent rule
  for an owned bitmap or thumbnail: write and durably publish its immutable
  AES-GCM file before a SQLCipher transaction may reference it. A crash can
  leave an encrypted orphan for later cleanup but never a committed row that
  points to an unfinished file. Deletion removes the database reference first
  and reclaims the file afterward. Decryption remains in process memory for
  preview, paste, recognition, and plugin actions; plaintext temporary files
  are forbidden. Authentication failure of one immutable payload makes only
  that entry's payload action unavailable and visible as an error; it never
  deletes the entry or resets an otherwise healthy store.
  _Avoid_: Plaintext Cache, Cross-filesystem Transaction, Payload Rollback.
- **Content Facet** (内容特征) — A filterable, non-exclusive classification
  derived from Clipboard Item content. The closed set is Text, Link, Email,
  Color, Image, Screenshot, File, and QR Code. A Clipboard Entry exposes the
  union of its items' facets, so one entry can match several filters without
  being duplicated: a PNG file is File and Image, a screenshot containing a QR
  code is Image, Screenshot, and QR Code, and textual URLs, email addresses, or
  colors also remain Text. OCR output is searchable derived data rather than a
  facet or a separate entry.
  _Avoid_: Clipboard Kind, Primary Category, OCR Entry.
- **Facet Classification** (内容特征识别) — Deriving Content Facets first
  from explicit Standard Clipboard Representations and only then from an Exact
  Text Payload. URL, color, file-URL, and image representations declare their
  corresponding facets directly. Text inference trims surrounding whitespace
  in a derived value but never changes the payload, and Link, Email, or Color
  must match that complete derived value. A URL embedded in prose remains Text
  and is still discoverable through ordinary search. File references gain
  Image only from declared resource or filename type without reading the file;
  derived OCR and QR strings never create Link, Email, or Color facets.
  _Avoid_: Substring Classification, Content Extraction, Trimmed Payload.
- **Link Facet Value** (链接特征值) — A complete derived text value recognized
  as a Link: an `http` or `https` URL, a bare domain, `localhost`, an IP address
  (each optionally carrying a port or path), or a syntactically valid custom
  `scheme://` deep link. Relative URLs, filesystem paths, templates, values
  containing internal whitespace, and the unsafe `javascript:`, `data:`, and
  `vbscript:` schemes are excluded. A `file://` URL is File rather than Link.
  Scheme completion or other normalization may be used only when opening the
  value and never mutates the Exact Text Payload. Email-specific schemes are
  classified separately. Explicit URL pasteboard representations obey the same
  unsafe-scheme and file-URL exclusions.
  _Avoid_: Embedded Link, Normalized Payload, File Link.
- **Email Facet Value** (邮箱特征值) — A complete derived text value containing
  either one valid mailbox or a valid `mailto:` URI with at least one
  recipient. A bare mailbox is Text and Email but not Link; a `mailto:` URI is
  Text, Email, and Link. Embedded addresses, display-name forms such as
  `Name <address@example.com>`, and comma-separated bare-mailbox lists remain
  searchable Text without the Email facet. Classification may remove
  surrounding whitespace in a derived value but never rewrites the Exact Text
  Payload.
  _Avoid_: Embedded Email, Contact, Recipient List.
- **Color Facet Value** (颜色特征值) — A complete derived text value that can be
  parsed as one supported color literal: `#RGB`, `#RGBA`, `#RRGGBB`,
  `#RRGGBBAA`, CSS `rgb()` / `rgba()` / `hsl()` / `hsla()` using either comma
  or modern space-and-slash syntax, or the exact
  `Color(red:..., green:..., blue:...)` form emitted by AnyDoor. A standard
  pasteboard color representation establishes Color without requiring text.
  Bare hexadecimal strings, named colors, CSS variables, gradients, and
  extended color functions such as `lab()` and `oklch()` are excluded.
  Classification requires a complete match and never rewrites the Exact Text
  Payload.
  _Avoid_: Color Name, Embedded Color, CSS Expression.
- **Screenshot Facet Provenance** (截图特征来源) — Proof that an image was
  produced by AnyDoor's own screenshot capture pipeline. Every bitmap is
  Image, but only an image carrying this first-party provenance is also
  Screenshot. Images copied from macOS Screenshot or another application remain
  Image because AppKit exposes no standard screenshot pasteboard type.
  Dimensions, filenames, PNG metadata, and source-application names are never
  treated as proof; a Finder file named like a screenshot is File and Image,
  not Screenshot.
  _Avoid_: Screenshot Heuristic, Screenshot Filename, Screenshot App Allowlist.
- **Automatic QR Indexing** (二维码自动索引) — Always-on, asynchronous,
  on-device QR recognition for bitmap payloads already saved in Clipboard
  History. It never blocks capture and has no user setting. Successful
  recognition attaches every decoded value and the QR Code facet to the same
  Clipboard Entry; it does not create a sibling record or replace the image.
  Plain text is never inferred to be QR content, while text produced by
  AnyDoor's explicit QR scanner receives the facet through first-party
  provenance. File Reference Entries are not opened or decoded for this
  indexing pass, even when their referenced files are images. Eligible
  captures persist a pending-index state across relaunches. Each receives at
  most three attempts, including the initial attempt; exhausting the budget
  silently marks only QR indexing as failed and never affects the image.
  Recapturing an identical bitmap creates a fresh indexing opportunity with a
  new three-attempt budget. No manual retry action is exposed. Automatic QR
  Indexing begins only with bitmap captures made after the new indexing system
  becomes active; it never backfills migrated or otherwise pre-existing
  images. Recapturing an old image makes that new capture eligible. A completed
  pass that finds no QR code is successful and receives no retry.
  _Avoid_: QR History Entry, Cloud QR Scan, File QR Scan.
- **Facet Filter** (内容特征过滤) — A single-select Clipboard History browsing
  constraint with an All state and the fixed order Text, Link, Email, Color,
  Image, Screenshot, File, and QR Code. It matches any entry carrying the
  selected Content Facet; overlap makes screenshots and image files visible
  through Image without requiring a Boolean query builder. It combines with
  text query, one optional source, one optional tag, and an independent
  favorite-only toggle using AND. Tag definitions retain their own display
  order rather than competing with facets in one category tab.
  _Avoid_: Multi-select Type Filter, Category Tab, Facet Expression.
- **History Exclusion Marker** (历史排除标记) — A recognized pasteboard type
  declaring that the current content is confidential, temporary, or not
  produced by an intentional user copy. The universal markers are
  `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, and
  `org.nspasteboard.AutoGeneratedType`. Compatibility markers from older
  password managers and text-expansion tools are `com.agilebits.onepassword`,
  `net.antelle.keeweb`, `de.petermaurer.TransientPasteboardType`,
  `com.typeit4me.clipping`, and `Pasteboard generator type`. The presence of
  any marker discards the capture before content reaches the Clipboard History
  Store. This rule is always active and has no user override; an Excluded
  Application is a separate, configurable source rule.
  _Avoid_: Sensitive Entry, Optional Privacy Filter, Custom Pasteboard Type.
- **Excluded Application** (排除应用) — A source application whose pasteboard
  changes Clipboard History does not capture. New installations initially
  exclude Apple Passwords (`com.apple.Passwords`) and Keychain Access
  (`com.apple.keychainaccess`). These defaults appear in the same editable list
  as user-added exclusions: the user may remove either default or add any
  installed application, such as a banking app. Any History Exclusion Marker
  remains authoritative even when its source application is allowed. AnyDoor
  does not automatically classify or exclude every third-party password
  manager. Upgrading users receive the two system defaults through a versioned
  one-time merge that preserves every existing exclusion. Removing a default
  after that migration is an explicit opt-out and it never returns
  automatically on launch or a later upgrade. Adding or removing an exclusion
  affects only future captures; “Ignore Source” keeps the selected history
  entry and Unknown cannot be turned into an application exclusion.
  _Avoid_: Blocked Application, Hardcoded Password Manager.
- **Universal Clipboard Source** (通用剪贴板来源) — The source assigned when
  Apple marks a general-pasteboard state with
  `com.apple.is-remote-clipboard`. It is captured by default and displayed as
  “Universal Clipboard” without guessing a device name or attributing it to
  the frontmost Mac application. A portable “Ignore Universal Clipboard”
  excluded-source rule, disabled by default, skips only future remote changes;
  turning it off never retroactively imports the current pasteboard.
  _Avoid_: Handoff App, Remote Application, iPhone Source.
- **File Reference Entry** (文件引用记录) — A new-capture Clipboard History
  entry created only when the pasteboard exposes one or more concrete local
  `file://` URLs. It preserves each capture-time path, display name, copy
  order, and regular non-security-scoped bookmark, but never copies file or
  directory contents into the Clipboard History Store and never materializes
  a file promise. Every member must resolve sufficiently to create a bookmark
  at capture time; one failure skips the complete Clipboard Entry rather than
  storing a partial collection. Legacy History Migration may additionally
  produce Legacy File References and migration-only Legacy Owned Files.
  Bookmark resolution runs without UI or automatic volume mounting; when the
  same file is moved or renamed on an available volume, AnyDoor updates its
  current display name and searchable path while retaining the capture-time
  path. Resolution never substitutes a different file later created at the old
  path. Referenced content is outside both History Storage Usage and AnyDoor's
  at-rest encryption; its encrypted database metadata remains searchable. If
  the bookmark cannot resolve because the original was deleted or its volume
  is unavailable, the entry remains visible but cannot paste that item and
  reports that the original file is unavailable. A multi-file entry is atomic:
  if any reference is unavailable, AnyDoor blocks the entire paste and reports
  the unavailable count instead of silently pasting a partial collection.
  _Avoid_: File Backup, Copied File Payload, Reference-only Entry.
- **Clipboard Capture Monitor** (剪贴板捕获监视器) — The single serialized
  pipeline that observes and records general-pasteboard states while monitoring
  is enabled. Passive monitoring remains enabled by default for new
  installations and is controlled by a device-local setting. It uses only
  public macOS APIs: a `Command-C` or `Command-X` event schedules a short
  high-frequency observation window, while a 500 ms
  `NSPasteboard.changeCount` fallback poll with timer tolerance — briefly
  raised after an observed non-keyboard change, and stopped while monitoring
  is off, during sleep, and while the screen is locked — captures menu
  actions, programmatic writes, and Universal Clipboard. Event-tap callbacks never read,
  classify, encode, or persist pasteboard content. A state overwritten before
  any observation cannot be recovered, so AnyDoor promises reliable normal
  human copying rather than absolute zero-loss capture for automated writes
  faster than its observation windows. Starting the app or re-enabling monitoring establishes the current
  pasteboard as a baseline and never imports it retroactively; only later
  changes are eligible. If monitoring remained enabled through system sleep,
  wake handling may capture the latest changed state but cannot reconstruct
  intermediate states overwritten during sleep. Private pasteboard SPI is
  excluded. The monitoring setting controls passive observation only;
  user-invoked AnyDoor screenshot, OCR, QR, and color actions continue to
  record their explicit outputs.
  _Avoid_: Clipboard Event Notification, Lossless Clipboard Capture.
- **Pasteboard Snapshot** (剪贴板快照) — An immutable in-memory copy of every
  selected Standard Clipboard Representation from one observed pasteboard
  generation. The monitor reads `changeCount` before and after the complete
  item sequence; a mismatch discards the snapshot and immediately observes the
  newest state, preventing one entry from mixing two generations. A private
  type may be ignored when its item also has supported content, but if any item
  has no persistable representation, the entire observed state is skipped
  rather than silently dropping an item. Empty and unsupported-only states are
  not history.
  _Avoid_: Live Pasteboard Reference, Partial Snapshot.
- **Capture Source** (捕获来源) — The best available attribution for the
  application or system channel that produced an observed pasteboard state,
  stored together with its provenance. Resolution precedence is Universal
  Clipboard Source, a non-empty `org.nspasteboard.source` declaration, the
  frontmost application sampled at a `Command-C` or `Command-X` event, then the
  frontmost application sampled when the change is observed. The last case is
  explicitly inferred; if none resolves, the source is Unknown. Excluded
  Application rules apply to both declared and inferred application sources,
  while detail UI distinguishes inference from a declared source.
  _Avoid_: Current App, Guaranteed Source App.
- **Exact Text Payload** (精确文本载荷) — The unmodified string representation
  captured from the pasteboard, including its original leading and trailing
  spaces, tabs, line endings, and whitespace-only content. Only a truly
  zero-length string is discarded. Search normalization and preview generation
  operate on derived values and never rewrite this payload; a whitespace-only
  entry receives a visible descriptive preview such as a space or line-break
  count. Duplicate identity uses the Exact Text Payload.
  _Avoid_: Trimmed Text, Normalized Payload, Empty-looking Entry.
- **Standard Clipboard Representation** (标准剪贴板表示) — An allowlisted
  pasteboard representation that Clipboard History may persist and restore:
  exact plain text; every supplied RTF, RTFD, and HTML rich-text form; URL plus
  its exact text; the standard color form plus a normalized color value; one
  orientation-applied lossless canonical PNG for still image content; or
  concrete file URLs backed by File Reference Entries. Normal paste writes
  every stored standard representation for the entry. Plain-text paste is
  available only when every Clipboard Item has an Exact Text Payload and
  restores those text items in order; it never silently omits an image or
  file-only item. Application-private types, unknown binary formats, PDF-only
  clipboard data, file promises, and History Exclusion Markers are never
  persisted. Rich-text extraction for preview or search never loads remote HTML
  resources.
  _Avoid_: Every Original Format, Private Pasteboard Payload, Richest Format.
- **History Text Edit** (历史文本编辑) — Replacing the content of a Clipboard
  Entry that contains exactly one Clipboard Item with an Exact Text Payload.
  Saving converts that item to exact plain text because its old rich, URL,
  color, or QR representations no longer describe the edit. A zero-length
  value is rejected, while whitespace-only text is valid. Facets, search
  fields, preview, and duplicate fingerprint update transactionally; id,
  source, capture time, favorite, and tags remain, an edit time is recorded,
  and Retention Start resets without moving recency. Equal content in another
  entry is not destructively merged.
  _Avoid_: Rich Text Edit, Edit as New Capture, Duplicate Merge.
- **Capture Safety Limit** (捕获安全上限) — A non-configurable per-entry guard
  of 128 MiB across the canonical plaintext bytes of all Standard Clipboard
  Representations selected for persistence, plus a 64-megapixel decoded-image
  limit, both aggregated across the complete Clipboard Entry. Referenced file
  contents do not count because AnyDoor never reads or stores them. Exceeding
  either limit rejects the entire history entry, leaves the system pasteboard
  unchanged, and shows one non-modal “content too large” notice for that
  observed change. It never silently stores a partial representation set. This
  is a memory and denial-of-service guard, not retention, disk-pressure
  management, or a total storage quota.
  _Avoid_: History Size Limit, Disk Quota, Partial Large Entry.
- **Retention Period** (保留期限) — The user-selected age window for Clipboard
  History entries that are not Protected Entries, chosen from fixed presets
  rather than an arbitrary custom duration. Presets are 1 day, 7 days, 30 days
  (the default), 3 months (90 elapsed days), 6 months (180 elapsed days),
  1 year (365 elapsed days), and Unlimited Retention; all are open to every
  user without an entitlement gate.
  _Avoid_: Custom Retention, Pro Retention, Clipboard History Size.
- **Protected Entry** (受保护记录) — A Clipboard History entry that is a
  favorite or has at least one assignment to a currently defined tag.
  Protected Entries do not expire under a finite Retention Period; tags
  intentionally provide both classification and retention. Deleting or
  importing away a tag definition removes that membership from local entries;
  entries losing their final protection receive a fresh Retention Start.
  _Avoid_: Pinned Entry, Permanent Entry.
- **Retention Start** (保留计时起点) — The time from which a non-protected
  entry's Retention Period is measured. It begins at capture and resets after a
  real duplicate capture, a committed History Text Edit, or the loss of final
  favorite-or-tag protection. A non-capture reset never changes the original
  capture time or the entry's recency order.
  _Avoid_: Created At, Last Modified.
- **Retention Reduction** (缩短保留期限) — A change to a shorter Retention
  Period. When it would expire existing entries, AnyDoor shows the number of
  affected non-protected entries and requires confirmation before deleting
  them; Protected Entries are never included. The new period and its deletions
  commit atomically, so failure preserves both the previous period and all
  entries. If the affected set changes while confirmation is open, the prompt
  refreshes instead of deleting a count the user did not approve.
  _Avoid_: History Reset, Clear History.
- **Clear History** (清空历史) — A user-initiated destructive operation that
  always opens a confirmation dialog. By default it deletes only non-protected
  entries. The dialog includes an unchecked “also clear tagged and favorite
  entries” checkbox; selecting it expands the operation to Protected Entries,
  and the displayed affected-entry count updates to match the current choice.
  Tag definitions, colors, ordering, settings, and the live system pasteboard
  survive either choice; the checkbox expands only the set of deleted history
  entries. The monitor advances its baseline so the current clipboard is not
  immediately captured again.
  _Avoid_: Retention Cleanup, Clear Automatically.
- **Expired Entry** (已过期记录) — A non-protected entry whose Retention Period
  has elapsed. It disappears from history and search immediately; physical
  storage reclamation may complete during maintenance within 24 hours. It is
  not eligible for duplicate reuse and never returns when the user later
  chooses a longer Retention Period.
  _Avoid_: Hidden Entry, Archived Entry.
- **Duplicate Capture** (重复捕获) — Capturing content identical to an existing
  Clipboard History entry reuses that entry instead of creating another one.
  The reused entry moves to the newest position and receives a fresh Retention
  Start, while its favorite state and tags remain intact. Identity is based on
  an ordered Clipboard Item fingerprint rather than search normalization: text
  preserves case and whitespace, rich text includes its formatting data, file
  collections preserve paths and order, and images compare the canonical
  orientation-applied lossless bitmap, including dimensions, component depth,
  alpha, and the applicable color profile while ignoring source encoding and
  unrelated metadata. Clipboard Item boundaries and order are part of the
  identity; the source application is not. A duplicate capture replaces the
  entry's source application and capture time with the most recent values; no
  source-history audit trail is retained, and source filters match only that
  latest application. A versioned SHA-256 fingerprint only selects candidates;
  canonical structure and payload digests are verified before reuse. Existing
  history paste or copy is a suppressed self-write, not a new capture, and does
  not change recency or Retention Start.
  _Avoid_: Duplicate Entry, Copy Event.
- **Unlimited Retention** (不限时间) — A Clipboard History policy in which an
  entry is never removed because of its age or the number of retained entries.
  It does not promise unlimited disk capacity: AnyDoor neither reserves space
  nor deletes older entries to recover it, and an exhausted volume instead
  causes a reported failure of the new write. Unlimited Retention is always an
  explicit user choice; new installations use a finite retention window.
  _Avoid_: Unlimited Records, Unlimited Capacity, 记录无上限.
- **History Storage Usage** (历史占用) — The total size of Clipboard History
  storage currently allocated by the file system under its dedicated boundary.
  It includes the database, WAL, shared-memory file, encrypted payloads and
  thumbnails, migration staging, and encrypted orphans awaiting cleanup. It is
  reported as one exact allocated-size total, refreshed after mutations and
  when Settings appears, not attributed approximately by content kind. It does
  not follow symlinks and excludes referenced source files, the current system
  pasteboard, and unrelated AnyDoor data.
  _Avoid_: Clipboard Size, Database Size, Logical Content Size.
- **Storage Pressure Policy** (存储压力策略) — Clipboard History does not
  monitor free-space thresholds, warn about predicted disk pressure,
  automatically shorten retention, or emergency-delete entries. Finite
  Retention Period and confirmed Clear History are its only deletion policies.
  A real failed write, including an out-of-space error, rejects only the new
  entry, preserves existing history and the system pasteboard, and produces one
  rate-limited non-modal operation failure.
  _Avoid_: Disk Quota, Emergency Pruning, Storage Warning.
- **Legacy History Migration** (旧历史迁移) — The one-time, pre-monitoring
  conversion from shared SwiftData rows and plaintext payloads into a complete
  encrypted staging store. Every retained legacy row remains a single-item entry
  with its id, order, source metadata, favorite, valid tags, and available
  payload preserved; migration never merges duplicates or backfills OCR or QR.
  The staged store is published only after integrity, row, index, and payload
  verification. Before publication, failure leaves all legacy data intact;
  after publication, cleanup is resumable. Legacy file manifests migrate
  member by member and may produce a mixed collection. An intact old copy is
  retired only when a size check and streamed SHA-256 digest prove that the
  current regular file has equal content; otherwise it becomes a Legacy Owned
  File. Any member without readable captured bytes becomes a Legacy File
  Reference because migration cannot prove its pre-migration identity.
  _Avoid_: In-place Migration, Partial Migration, Legacy File Backup.
- **Legacy File Reference** (旧文件引用) — A file member preserved by Legacy
  History Migration without readable captured bytes, whether its old manifest
  was path-only or its named copy is now missing. If the path resolves during
  migration, AnyDoor creates a bookmark with legacy-unverified provenance:
  identity is guaranteed only from migration onward, not for the original
  capture. If it does not resolve, the path stays searchable as an unavailable
  reference without a bookmark and never auto-binds to a later file at that
  path. Either state records uncertainty without inventing historical content
  or asking the user to confirm its loss.
  _Avoid_: Verified Original, Recovered File.
- **Legacy Owned File** (迁移保留文件) — An encrypted owned payload created
  only by Legacy History Migration when an intact legacy copy cannot be proven
  redundant against the current regular file. A missing, changed, replaced,
  unreadable, or otherwise unverifiable current path therefore preserves the
  copy instead of deleting it. The payload counts toward History Storage Usage
  and follows normal retention and protection. Any owned or unavailable member
  blocks normal paste of its complete collection.
  Restore File… or Restore Files… writes all owned members to explicit
  user-chosen destinations and creates their bookmarks before one database
  transaction converts them to ordinary references. A partial failure retires
  no encrypted payload and leaves the history state retryable, although
  already-written user-owned output files may remain. Restore keeps
  capture-time paths and the duplicate fingerprint unchanged. New captures
  never create a Legacy Owned File.
  _Avoid_: Migration Backup, Hidden Copy.
- **Search Relevance** (搜索相关性) — The ordering used for a non-empty
  Clipboard History query. A complete-query whole-field match ranks before a
  field prefix, which ranks before a continuous substring; otherwise every
  query term uses its best field match and the weakest term controls the entry's
  class. Within one class, visible copied content, file names, QR values, and
  color values outrank image-recognition text, which outranks capture-time and
  current file paths. Aggregate class, field priority, recency, and stable id
  break subsequent ties. An empty query remains strictly recency-ordered.
  _Avoid_: Search Order, Recent First.
- **History Result Page** (历史结果页) — A cursor-addressed batch of 100
  lightweight Clipboard History entries. History and search load the first page
  immediately and prefetch subsequent pages near the visible end; no query has
  a total-result cap. An opaque keyset cursor binds query, filters, index
  generation, ranking tuple, capture time, and id; changed inputs or index
  generation restart at page one rather than mixing result generations. Page
  size is an internal invariant rather than a user setting, and offset
  pagination is excluded.
  _Avoid_: Search Limit, Load All, Page Number.
- **Searchable Content** (可搜索内容) — Payload-derived text searched by a
  Clipboard History query: copied text, text extracted from rich content or
  images, QR-code content, color values, file names, and file paths. Both
  capture-time and bookmark-resolved current paths are included.
  Source apps, tags, content kinds, dates, and display-only metadata remain
  explicit filters rather than searchable text.
  _Avoid_: Search Metadata, Search Everything.
- **Automatic Image Text Indexing** (图片文字自动索引) — An opt-in Clipboard
  History setting, disabled by default. Only images and screenshots captured
  with an owned bitmap payload while it is enabled are processed asynchronously
  with on-device text recognition after their payload is saved; referenced
  image files are never opened, and enabling the setting never backfills
  existing entries. The setting includes a subordinate tip that makes this
  activation boundary explicit. Disabling the setting prevents later captures
  from becoming eligible but lets already pending eligible work finish and
  retains text already indexed, which remains searchable.
  Recognized text joins the same entry's Searchable Content; it neither blocks
  capture nor creates a second history entry, and it is never uploaded for
  recognition. Recognition always uses the high-accuracy mode; AnyDoor does not
  expose a separate quality setting. Eligible captures persist a pending-index
  state until recognition completes, so interrupted work resumes after relaunch
  without scanning entries captured before the setting was enabled. Each entry
  receives at most three recognition attempts, including the initial attempt;
  exhausting them marks only its text index as failed and never removes or
  blocks the original history entry. Final failure is silent and offers no
  user-facing retry or warning. Recapturing an identical image while indexing
  is enabled makes its reused entry eligible again and grants a fresh
  three-attempt budget, even when the entry predates enablement or previously
  exhausted its attempts; this is a new capture, not a history backfill. A
  completed recognition pass that finds no text is successful and is not
  retried.
  _Avoid_: Automatic OCR History, Cloud OCR.
- **Search Match** (搜索匹配) — A case-, diacritic-, and width-insensitive prefix
  or continuous-substring match, including unsegmented CJK text. Every query
  term must match the same entry; spelling correction and edit-distance
  matching are excluded. Matching begins with the first entered character:
  one- and two-character terms return complete indexed results without a
  minimum-length gate or a full-history scan. Locale-independent normalized
  search fields use encrypted FTS5 trigram candidates for terms of three or
  more Unicode code points and a second encoded unigram/bigram FTS5 index for
  shorter terms; candidates are always verified by a real continuous-substring
  comparison. Missing FTS5 support is an invalid build, never a reason to fall
  back to a linear scan.
  _Avoid_: Fuzzy Match, Semantic Match.

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

## Config Sync & Backup

- **Config Sync** (配置同步) — Optional automatic convergence of Portable
  Settings across a user's machines through a shared storage location. Off by
  default; requires no account. Distinct from **Config Backup**.
  _Avoid_: calling manual export/import "同步".
- **Config Backup** (配置备份) — A one-shot manual export or import of the
  portable configuration as a single file, for migration or sharing. It does
  not converge machines; that is Config Sync's job.
- **Sync Folder** (同步文件夹) — The user-chosen folder that brokers Config
  Sync, typically inside a cloud drive's local mount. AnyDoor only reads and
  writes local files there; whatever syncs the folder is the transport.
- **Device State File** (设备状态文件) — The single file in the Sync Folder
  that one machine writes: its full Sync Document. Every machine writes only
  its own file and reads all others, so no file ever has two writers.
- **Sync Document** (同步文档) — A machine's mergeable view of its portable
  configuration: one entry per configuration record, each carrying a
  modification clock and possibly a Tombstone. Merging two documents is
  deterministic and order-independent; concurrent edits to the same record
  resolve to the newer clock.
- **Tombstone** (墓碑) — A retained deletion marker in a Sync Document. It
  stops a deleted record from being resurrected by a machine that still
  carries it; expired Tombstones are garbage-collected.
- **Portable Setting** (可携带设置) — A configuration value allowed to travel
  between machines, enumerated by a single whitelist.
- **Machine-Local Setting** (机器本地设置) — A setting that deliberately never
  travels (e.g. helper approval, Script Plugin state, the Sync Folder choice
  itself). Not a Portable Setting.
