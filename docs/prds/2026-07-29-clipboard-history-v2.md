# PRD: Clipboard History v2

- **Status:** approved — final review passed 2026-07-30
- **Date:** 2026-07-29
- **Glossary:** [Clipboard History](../../CONTEXT.md#clipboard-history)
- **Research:** [Raycast Clipboard History research](../research/2026-07-29-raycast-clipboard-pro-research.md)
- **Architecture:** ADR-0011 through ADR-0025

## Problem

Clipboard History currently has two user-visible failure modes:

1. a plain 500 ms pasteboard poll with no event assistance can miss an
   intermediate value that another write overwrites before the next tick; and
2. in-memory filtering over SwiftData rows does not scale to long or unlimited
   retention and gives weak, sometimes incomplete search behavior.

The feature also lacks one explicit contract for retention, protected entries,
file ownership, disk usage, encryption, multi-item pasteboard states, migration,
and derived OCR or QR data. Fixing only the search field would leave those
boundaries contradictory.

## Outcome

Clipboard History becomes a device-local, encrypted, indexed clipboard store
that:

- captures normal human copy operations with low latency using public macOS
  APIs;
- preserves the complete supported multi-item pasteboard state;
- searches all retained entries with exact, prefix, and substring relevance,
  including complete one- and two-character CJK results;
- offers finite time presets or explicit Unlimited Retention with no hidden
  count cap;
- protects favorites and tagged entries from age expiry;
- reports its exact allocated storage footprint without attempting to manage
  macOS disk pressure; and
- migrates existing history without silently losing the only readable copy.

Every feature is available to every AnyDoor user. There is no paid Clipboard
History tier or entitlement path.

## Product Contract

### Capture and privacy

- Passive Clipboard monitoring remains a device-local setting and retains the
  current default of enabled for new installations.
- Launch, re-enable, unlock, and migration completion establish the current
  `NSPasteboard.changeCount` as a baseline. They never import clipboard content
  that predates active observation.
- `Command-C` and `Command-X` schedule a short observation burst. A 500 ms
  `changeCount` fallback with at least 50 ms timer tolerance covers menu
  actions, programmatic writes, accessibility actions, and Universal
  Clipboard; an observed non-keyboard change briefly raises the frequency, and
  the timer stops while monitoring is off, during sleep, and while the screen
  is locked.
- All reads and persistence stay outside the CGEvent callback. A serialized
  pipeline verifies `changeCount` before and after each complete in-memory
  Pasteboard Snapshot.
- This substantially improves ordinary capture reliability but does not claim
  recovery of programmatic states overwritten between observations.
- History Exclusion Markers always discard a state before payload bytes are
  read and cannot be overridden.
- New installations initially exclude Apple Passwords and Keychain Access.
  Those defaults are editable and migrate once without resurrecting a default
  the user later removed.
- Universal Clipboard is captured by default and labeled without guessing its
  device or app. “Ignore Universal Clipboard” is a portable future-capture rule
  that defaults off.
- Exclusion changes affect only later observations. They do not delete or
  retroactively import history.
- The monitoring switch controls passive observation. Explicit AnyDoor
  screenshot, OCR, QR, and color actions continue recording their
  user-initiated outputs.

### Pasteboard state and supported content

- One eligible pasteboard generation becomes one Clipboard Entry containing
  ordered Clipboard Items. Item boundaries and order survive normal paste.
- The persistent allowlist is exact plain text; all supplied RTF, RTFD, and
  HTML; URL plus exact text; standard color plus normalized color; one
  orientation-applied lossless PNG for a still bitmap; and concrete file URLs.
- Application-private data, unknown binary formats, PDF-only clipboard data,
  file promises, and exclusion markers are not stored.
- A private type may be ignored when the same item has supported data. If any
  item has no supported representation, the complete observed state is skipped
  rather than shortened silently.
- Only a truly zero-length plain string is absent. Whitespace, tabs, and line
  endings are preserved exactly.
- Normal paste restores every stored representation and item in order.
  Plain-text paste is available only when every item has exact text, so it never
  drops an image or file-only item silently.
- The aggregate entry limit is 128 MiB of canonical plaintext representations
  and 64 megapixels of decoded bitmap content. Exceeding either rejects the
  complete entry and shows one non-modal notice.

### File references

- A file entry requires concrete `file://` URLs and successfully created
  ordinary, non-security-scoped bookmarks for every member.
- AnyDoor stores encrypted path, name, order, and bookmark metadata but never
  copies file or directory contents and never materializes promises.
- Bookmarks follow a move or rename on an available volume without mounting a
  volume or falling back to a different file later created at the old path.
- An unavailable reference remains searchable. Any unavailable member blocks
  normal paste of the complete mixed or file-only entry and reports the missing
  count.
- Referenced image files gain Image through declared type metadata but are not
  opened for OCR or QR indexing.

### Content facets and filtering

- Content facets are overlapping, not a primary enum: Text, Link, Email, Color,
  Image, Screenshot, File, and QR Code.
- The Facet Filter is single-select with All and a fixed order. One source, one
  tag, and favorite-only are separate optional AND constraints.
- Link, Email, and Color inference requires the complete trimmed derived text
  value. Embedded values remain searchable Text without broadening facets.
- Link accepts HTTP(S), bare hosts, localhost, IP addresses, and valid
  `scheme://` deep links. It excludes relative values, file URLs, templates,
  internal whitespace, and `javascript:`, `data:`, or `vbscript:`.
- A bare mailbox is Text and Email. A valid `mailto:` URI is Text, Email, and
  Link. Display-name forms and mailbox lists remain ordinary Text.
- Color recognizes explicit pasteboard color data and the documented hex, CSS
  RGB/HSL, and AnyDoor SwiftUI forms. It excludes bare hex, names, variables,
  gradients, and extended color functions.
- Every bitmap is Image. Screenshot additionally requires AnyDoor first-party
  capture provenance; dimensions, filenames, metadata, and source app names are
  never screenshot heuristics.
- Derived OCR and QR strings do not recursively add Link, Email, or Color.

### OCR and QR

- Automatic Image Text Indexing is device-local, disabled by default, uses
  on-device Vision accurate recognition, and has no quality selector.
- Its setting explains that only bitmap captures made while enabled are
  eligible. Enabling never backfills. Disabling prevents later eligibility but
  lets already pending jobs finish and retains indexed text.
- QR indexing is always-on, asynchronous, and on-device for newly captured
  owned bitmaps. It has no setting and never scans file references or migrated
  images.
- OCR text and all decoded QR values attach to the same entry. Neither creates
  a sibling history record or changes normal image paste.
- Each eligible derived job persists across relaunch and receives three attempts
  including the first. Final failure is silent. A successful empty result does
  not retry. A real duplicate recapture grants a fresh budget.

### Search

- Empty search is strictly newest-first. Non-empty search is case-, diacritic-,
  and width-insensitive and splits on whitespace with AND semantics.
- Exact complete-field matches rank before prefixes, then continuous
  substrings. Visible copied content, file names, QR values, and normalized
  colors outrank OCR, which outranks file paths; recency and id are final ties.
- Searchable data includes exact and rich-derived text, OCR, QR values,
  normalized colors, file names, and both capture-time and current paths.
  Sources, tags, facets, dates, and display metadata remain filters.
- Encrypted FTS5 trigram candidates serve terms of three or more normalized
  Unicode code points. Encoded unigram and bigram FTS5 candidates serve shorter
  terms. Both tables are queried only with MATCH; candidate values are always
  verified against the authoritative field row by a real substring comparison.
- User input is literal data, never raw FTS syntax. Missing FTS5 or trigram
  support is an invalid build, not permission for a linear fallback.
- Field rows and both FTS tables mutate in one transaction. Deletes remove the
  external-content trigram entry while the old field value still exists,
  remove the short-gram entry, and then remove the field row. Updates remove
  old index entries before replacing the field and inserting new index entries.
  Both FTS tables enable persistent FTS5 `secure-delete=1` in addition to
  SQLite core `PRAGMA secure_delete=ON`.
- Results use opaque keyset pages of 100 with no total cap. Query, filter, or
  index-generation changes restart pagination instead of mixing generations.
- Search indexes are derived and rebuildable. Recency browsing remains
  available during rebuild; search shows indexing rather than incomplete
  results.

### Retention, protection, and deletion

- Presets are 1 day, 7 days, 30 days (default), 3 months (90 days), 6 months
  (180 days), 1 year (365 days), and Unlimited.
- Retention is age-only. There is no hidden item count, disk quota, LRU
  eviction, or paid limit.
- Favorite or any valid tag protects an entry indefinitely from finite
  retention.
- New capture and real duplicate capture set Retention Start. Losing final
  protection or explicitly editing text resets it without changing recency.
- Previewing, copying, or pasting a history entry is usage, not capture. It does
  not move the entry, replace source attribution, or extend retention.
- Shortening retention first computes the exact currently affected count. A
  nonzero count requires confirmation, and the new period and deletion then
  commit atomically; a changed count refreshes the prompt. A zero-count change
  takes effect immediately because it deletes nothing.
- Expired entries disappear from history, search, counts, and duplicate reuse
  immediately. Encrypted physical storage is reclaimed within 24 hours and
  never resurrected by a longer later period.
- Clear History always confirms. Its default scope excludes protected entries.
  An unchecked checkbox adds tagged and favorite entries and updates the count.
  Tag definitions, settings, and the live pasteboard survive either scope.
- Deleting or importing away a tag definition removes that membership from
  local entries. Entries losing final protection receive a fresh retention
  window instead of disappearing immediately.

### Text editing

- Editing is available only for a one-item entry with exact text.
- Saving creates a plain-text representation set, dropping old rich, URL,
  color, and QR provenance that no longer describes the edited content.
- Zero-length edits are invalid; whitespace-only edits are valid.
- Search fields, facets, preview, and fingerprint update transactionally.
  Entry id, source, capture time, favorite, and tags stay intact; edit time and
  Retention Start update without moving recency.
- Equal content in another entry is not auto-merged because protection metadata
  belongs to each entry independently.

### Storage, encryption, and failure behavior

- GRDB accesses one dedicated community-SQLCipher database through the pinned
  packages in ADR-0013. The Clipboard History target does not directly link
  the system SQLite library; GRDB's SQLite imports bind to SQLCipher. Owned
  bitmaps, thumbnails, and migration-only Legacy Owned Files use immutable
  AES-GCM files. Independent HKDF-derived keys prevent direct key reuse.
- The device-only Keychain item uses a fixed service/account shared by
  development and installed process identities. It is never synced or backed
  up.
- A locked Keychain pauses capture and resumes from a new baseline after
  unlock. A missing key or unreadable database never triggers silent reset.
- Store Unavailable exposes retry and an explicitly confirmed Reset Clipboard
  History action. One corrupt payload disables only that entry's payload action.
- Payloads publish encrypted and durably before a database transaction may
  reference them. Database deletion precedes asynchronous file reclamation.
  Crashes may leave encrypted orphans, never plaintext files or committed
  references to unfinished files.
- Previews, paste, OCR, QR, and plugins receive decrypted memory. Clipboard
  content, paths, search terms, and recognized values never enter persistent
  plaintext caches, temporary files, or logs.
- History Storage Usage is the exact file-system allocated total for the
  dedicated database, WAL, shared memory, encrypted payloads and thumbnails,
  migration staging, and encrypted orphans. It excludes reference targets.
- AnyDoor does not monitor or warn about predicted disk pressure and never
  emergency-deletes history. An actual write failure rejects the new entry,
  preserves existing history and the pasteboard, and reports one rate-limited
  operation error.

### Migration

- Migration runs before monitoring and builds a complete encrypted sibling
  staging store while legacy SwiftData and plaintext payloads remain intact.
- Every retained legacy row remains a single-item entry. Stable id, order,
  source metadata, favorite, valid tags, and available payload are preserved.
  Existing duplicates are not merged.
- Legacy Text, Color, QR, OCR, Image, Screenshot, and File map according to
  ADR-0020. Legacy standalone OCR becomes Text because its image relation cannot
  be reconstructed.
- Existing owned images and screenshots become encrypted payloads without OCR
  or QR backfill.
- Legacy file manifests migrate member by member and may already mix copied
  members with path-only members. An intact legacy copy becomes an ordinary
  reference only when a size check and streamed SHA-256 digest prove that the
  current regular file has equal content. Missing, changed, replaced,
  unreadable, or otherwise unverifiable current content preserves the copy as
  an encrypted Legacy Owned File, even when the old path now exists.
- A legacy member without readable captured bytes, whether path-only in the
  manifest or missing its named copy, cannot be content-verified. A resolving
  path receives a bookmark with legacy-unverified provenance and an identity
  guarantee beginning at migration. A non-resolving path remains a searchable
  unavailable legacy reference without a bookmark and never auto-binds to a
  later file at the same path. Migration keeps that record without a discard
  confirmation.
- One migrated collection may mix ordinary, legacy-unverified, unavailable,
  and owned members. Any owned or unavailable member blocks complete normal
  paste. Restore File… or Restore Files… writes every owned member to explicit
  user-chosen destinations and creates every replacement bookmark before one
  database transaction converts all owned members. A partial failure retires no
  encrypted payload and leaves the history state retryable; user-owned output
  files already written before the failure may remain at their destinations.
  Restore never changes capture-time paths or the duplicate fingerprint.
- Integrity, row/id, foreign-key, search-index, and authenticated payload checks
  precede atomic publication. Failure before publication leaves legacy data
  intact; cleanup after publication is independently resumable.

### Module seam

- A new `ClipboardHistory` Swift Package target owns capture classification,
  persistence, encryption, search, retention, migration, derived jobs, and
  maintenance behind one concrete `ClipboardHistoryModule`.
- Its external interface is limited to passive-observation control, explicit
  capture, paged query, typed mutation, materialization, and status.
- App focus, synthetic paste, SwiftUI, localization, and plugin presentation
  stay in the host. GRDB rows, SQL, Keychain handles, and encrypted payload URLs
  never cross the interface.
- `AppDelegate` constructs and injects one instance. The existing mutable
  `ClipboardHistoryStore.shared` and persistence-aware SwiftUI queries are
  removed rather than wrapped.

## Architecture Decisions

- [ADR-0011: Isolate Clipboard History storage](../adr/0011-isolate-clipboard-history-storage.md)
- [ADR-0012: Treat tagged entries as protected](../adr/0012-tags-protect-clipboard-entries.md)
- [ADR-0013: Use dedicated SQLite](../adr/0013-use-sqlite-for-clipboard-history.md)
- [ADR-0014: Encrypt Clipboard History at rest](../adr/0014-encrypt-clipboard-history-at-rest.md)
- [ADR-0015: Reference original files](../adr/0015-reference-original-files-from-clipboard-history.md)
- [ADR-0016: Use event-assisted polling](../adr/0016-use-event-assisted-pasteboard-polling.md)
- [ADR-0017: Persist standard representations](../adr/0017-persist-only-standard-clipboard-representations.md)
- [ADR-0018: Preserve pasteboard item groups](../adr/0018-preserve-pasteboard-item-groups.md)
- [ADR-0019: Model overlapping content facets](../adr/0019-model-content-types-as-overlapping-facets.md)
- [ADR-0020: Migrate through a staging store](../adr/0020-migrate-legacy-clipboard-history-through-a-staging-store.md)
- [ADR-0021: Use trigram and short-gram indexes](../adr/0021-use-trigram-and-short-gram-indexes-for-clipboard-search.md)
- [ADR-0022: Publish encrypted payloads first](../adr/0022-publish-encrypted-payloads-before-database-references.md)
- [ADR-0023: Use age-only retention](../adr/0023-use-age-only-retention-with-explicit-protection.md)
- [ADR-0024: Verify duplicate fingerprints](../adr/0024-verify-canonical-fingerprints-before-reusing-clipboard-entries.md)
- [ADR-0025: Encapsulate a deep module](../adr/0025-encapsulate-clipboard-history-as-a-deep-module.md)

## Implementation Tickets

- [026: Deep module and SQLCipher seam](../issues/026-clipboard-history-module-foundation.md) ([GitHub #79](https://github.com/ZingerLittleBee/AnyDoor/issues/79))
- [027: Encrypted store, schema, keys, and payloads](../issues/027-clipboard-history-encrypted-store.md) ([GitHub #80](https://github.com/ZingerLittleBee/AnyDoor/issues/80))
- [028: Complete capture model and standard representations](../issues/028-clipboard-history-capture-model.md) ([GitHub #81](https://github.com/ZingerLittleBee/AnyDoor/issues/81))
- [029: Canonical fingerprint verification and duplicate reuse](../issues/029-clipboard-history-duplicate-reuse.md) ([GitHub #82](https://github.com/ZingerLittleBee/AnyDoor/issues/82))
- [030: Event-assisted pasteboard monitor and source policy](../issues/030-clipboard-history-monitor.md) ([GitHub #83](https://github.com/ZingerLittleBee/AnyDoor/issues/83))
- [031: Encrypted substring search, ranking, and pages](../issues/031-clipboard-history-indexed-search.md) ([GitHub #84](https://github.com/ZingerLittleBee/AnyDoor/issues/84))
- [032: Retention, protection, mutations, and maintenance](../issues/032-clipboard-history-retention-and-mutations.md) ([GitHub #85](https://github.com/ZingerLittleBee/AnyDoor/issues/85))
- [033: Persisted OCR and QR indexing jobs](../issues/033-clipboard-history-derived-indexing.md) ([GitHub #86](https://github.com/ZingerLittleBee/AnyDoor/issues/86))
- [034: Staged legacy migration and owned-file restore](../issues/034-clipboard-history-legacy-migration.md) ([GitHub #87](https://github.com/ZingerLittleBee/AnyDoor/issues/87))
- [035: Paged host presentation, preview, and paste actions](../issues/035-clipboard-history-host-presentation.md) ([GitHub #88](https://github.com/ZingerLittleBee/AnyDoor/issues/88))
- [036: Settings, migration UI, and production lifecycle](../issues/036-clipboard-history-settings-and-production-lifecycle.md) ([GitHub #89](https://github.com/ZingerLittleBee/AnyDoor/issues/89))
- [037: Legacy cutover and release acceptance](../issues/037-clipboard-history-cutover-and-acceptance.md) ([GitHub #90](https://github.com/ZingerLittleBee/AnyDoor/issues/90))

Dependency order:

1. 026 → 027 → 028.
2. 029, 030, and 031 may proceed independently after 028.
3. 032 follows 029 and 031; 033 follows 031 and 032.
4. 034 and 035 may proceed independently after their listed prerequisites.
5. 036 joins monitoring, migration, and presentation in production.
6. 037 removes the legacy path and runs the complete release gates.

## Non-goals

- Cloud sync, Config Backup, export, or import of history content.
- Custom retention durations, count limits, disk quotas, or disk-pressure
  management.
- Fuzzy, typo-tolerant, semantic, or cloud search.
- Private pasteboard APIs or a zero-loss claim for unobservable overwritten
  states.
- Persisting every private source-app representation.
- Copying referenced files as backup or materializing file promises; the
  one-time migration retention of a legacy copy that cannot be proven
  redundant is the sole exception.
- OCR backfill, QR backfill, or OCR/QR of referenced image files.
- Heuristic classification of external images as screenshots.
- Automatic third-party password-manager classification.

## Acceptance Gates

- Deterministic capture tests cover event hints, fallback ticks, source
  precedence, exclusions, self-writes, generation changes during read, mixed
  items, unsupported-only items, and rapid overwrite limits.
- The idle fallback produces no more than two timer fires per second. A
  fixed-duration idle trial measures wakeups, CPU, and Energy Impact against
  the existing plain 500 ms polling baseline and permits no material regression
  beyond measurement noise. The consecutive-copy loss-rate benchmark measures
  event-assisted bursts separately.
- Storage fault-injection covers payload publication, database transaction,
  clear/retention deletion, orphan reconciliation, disk-full failure, locked or
  missing keys, corruption, and explicit reset.
- Migration fixtures cover every legacy kind, protected and expired entries,
  duplicates, copied/path-only mixtures, equal and changed same-path files,
  replaced and missing paths, owned and unavailable members, single- and
  multi-member restore failures, corrupt payloads, crash boundaries, retry,
  and verified cleanup.
- Search fixtures cover CJK, Latin, diacritics, full-width text, emoji,
  punctuation, exact/prefix/substring relevance, one- and two-character terms,
  multi-item fields, cursor invalidation, index rebuild, mutation-order
  rollback, stale-token rejection, FTS integrity checks, and persistent FTS5
  secure deletion on both tables.
- Search performance is measured on a large retained corpus for empty,
  one-character, two-character, and long substring queries, plus
  secure-delete-heavy retention cleanup. Implementation is incomplete until
  first-page latency and memory remain interactive on the minimum supported
  hardware.
- The native-arm64 approval spike recorded in ADR-0013 has already proved the
  pinned dependency build, encrypted reopen behavior, wrong-key rejection,
  FTS5 trigram and short-gram behavior, FTS5 secure deletion, and direct
  SQLCipher linkage. Universal arm64 and x86_64 builds remain required to prove
  both architectures and final executable binding.
- `sqlcipher/GRDB.swift` and `sqlcipher/SQLCipher.swift` are pinned in SwiftPM
  per ADR-0013, their licenses are added to `THIRD-PARTY-LICENSES.md`, and
  release-binary size impact is measured and reported before acceptance.

## Review State

Approved on 2026-07-30. This PRD and ADR-0011 through ADR-0025 are the
implementation decision baseline.

No product decision remains intentionally open. Measured SQLCipher bundle-size
impact, concrete schema names, benchmark numbers, and UI copy are
implementation-validation details, not permission to weaken the contract
above. Source implementation proceeds only through reviewed dependency-ordered
tickets.
