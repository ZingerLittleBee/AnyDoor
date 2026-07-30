# Clipboard History v2 Manual Test Plan

The automated suite covers the store, the search index, migration boundaries,
and crash safety. It cannot cover what this feature is actually judged on:
whether copying feels instant, whether the wall opens without a hitch, whether
a year of history still types smoothly, and whether the app costs anything
while sitting idle in the menu bar. This plan covers that.

Scope: the contract in `docs/prds/2026-07-29-clipboard-history-v2.md`
(ADR-0011 through ADR-0025). Cases are traced to that contract; a case that
contradicts it is a bug in this plan, not licence to change behaviour.

## How to read this

Each case has **Steps**, **Pass**, and where it matters a **Budget** — a number
that decides pass or fail. Budgets are not aspirations; exceeding one is a
defect, not a note.

- **P0** — must pass before merge. Failure loses or exposes user data.
- **P1** — must pass before release. Failure is a bad experience.
- **P2** — record the result, decide separately.

Negative cases are marked **(must not)**. They matter more than the positive
ones: this feature's contract is mostly about what it refuses to do.

---

## 0. Preparation

### 0.1 Builds and hardware

Test the **installed** app, not `swift run`. They are separate process
identities with separate Accessibility grants, and only the installed one has
the production Bundle ID that the Keychain item and the URL scheme key off.

```bash
make install          # /Applications/AnyDoor.app, Bundle ID dev.bybee.AnyDoor
```

Coverage matrix — the PRD requires the feature to stay interactive on the
**minimum supported hardware**, and CI only type-checks the x86_64 branch:

| Machine | Priority | Why |
| --- | --- | --- |
| Apple Silicon, current | P0 | Primary |
| Intel Mac on macOS 14 | P1 | Oldest supported; SQLCipher and FTS5 perf differ. Every budget in section 8 must be re-measured here, not assumed. |
| Universal build from `scripts/release.sh` | P1 | The shipped artifact, not the debug one |

### 0.2 Store locations

```
~/Library/Application Support/dev.bybee.AnyDoor/
  AnyDoor.store                            # SwiftData — must contain no clipboard rows in v2
  ClipboardHistory/
    history.sqlite, -wal, -shm             # SQLCipher
    payloads/                              # AES-GCM envelopes
    staging/
  ClipboardHistoryLegacyMigration/         # exists only mid-migration
  ClipboardHistoryLegacyCutover-v1.complete
```

Keychain: one device-only generic-password item, never synced, never backed up.

### 0.3 Building a large history

**A. Drive real captures** (exercises the whole pipeline):

```bash
for i in $(seq 1 2000); do
  printf 'fixture %d %s\n' "$i" "$(head -c 200 /dev/urandom | base64)" | pbcopy
  sleep 0.12
done
```

Vary it: CJK, emoji, URLs, long code blocks, periodic images
(`screencapture -c`).

**B. Disposable-home legacy fixture** (for migration cases, does not touch
your real history):

```bash
CLIPBOARD_HISTORY_GUI_FIXTURE=1 CFFIXED_USER_HOME=/tmp/anydoor-fixture \
  swift test --filter ClipboardHistoryGUIFixtureTests/testCreateDisposableLegacyMigrationFixture
```

### 0.4 Measuring

- **Perceived latency** — screen-record at 60fps and count frames. One frame
  is 16.7ms; more honest than a stopwatch below half a second.
- **Frame drops** — Instruments → Animation Hitches. "Looks smooth" is not a
  result.
- **Memory** — Activity Monitor's *Memory* column is `phys_footprint`, what
  the OS kills on. Record idle, peak, and settled-after.
- **Idle cost** — Activity Monitor → Energy, plus
  `powermetrics --samplers tasks -n 1 | grep -i anydoor` for wakeups/sec.
  Section 8.11 depends on this.
- **Who is stalling** — `sample AnyDoor 3 -file /tmp/sample.txt` while
  reproducing tells you whether it is AnyDoor or the target app.
- **Disk** — `du -sh` the store root; compare against Settings → Clipboard's
  reported usage. They must agree.

### 0.5 Before each destructive case

```bash
cp -R ~/Library/Application\ Support/dev.bybee.AnyDoor /tmp/anydoor-backup-$(date +%s)
```

---

## 1. Migration from pre-v2 — P0

Runs exactly once per user and has never been exercised on a real install.
Highest-risk area in the branch.

### 1.1 Basic paths

| # | Case | Pass |
| --- | --- | --- |
| 1.1.1 | Fresh install (no `dev.bybee.AnyDoor` directory) | Empty history, no error, no migration UI. Cutover marker written. |
| 1.1.2 | ~50 legacy entries | All present, same order, same favorites and tags. |
| 1.1.3 | 5000+ legacy entries incl. images | See budget in 8.12. All migrate. |
| 1.1.4 | Legacy tags, favorites, category order | All preserved; tag definitions intact. |
| 1.1.5 | Legacy retention preset | Same preset selected after migration. |
| 1.1.6 | Second launch | No migration runs; snapshot directory absent; marker present. |
| 1.1.7 | Unknown legacy `ZKIND` | That row skipped; every other row migrates. **(must not)** fail wholesale. |

### 1.2 Legacy kind mapping (ADR-0020)

| # | Legacy kind | Pass |
| --- | --- | --- |
| 1.2.1 | Text | Text entry, searchable. |
| 1.2.2 | Color | Color facet, normalized value searchable. |
| 1.2.3 | QR | Decoded value retained and searchable. |
| 1.2.4 | **Standalone OCR** | Becomes **Text**, not an image-derived entry — its image relation cannot be reconstructed. |
| 1.2.5 | Image | Encrypted payload, Image facet. |
| 1.2.6 | Screenshot | Screenshot facet retained. |
| 1.2.7 | File | See 1.3. |
| 1.2.8 | **No OCR/QR backfill** | **(must not)** run recognition over migrated images, even with Image Text Indexing on. |
| 1.2.9 | Existing duplicates | **(must not)** be merged. Two identical legacy rows stay two entries. |

### 1.3 Legacy file members — the subtle part

The contract decides per member whether the legacy copy can be retired.

| # | Setup | Pass |
| --- | --- | --- |
| 1.3.1 | Legacy copy + current file at the same path with **identical** content | Size check and streamed SHA-256 agree → becomes an ordinary reference; the encrypted copy is retired. |
| 1.3.2 | Legacy copy + current file at the same path with **changed** content | Copy is preserved as a Legacy Owned File. **(must not)** silently adopt the different file. |
| 1.3.3 | Legacy copy, path now missing | Copy preserved as Legacy Owned File. |
| 1.3.4 | Legacy copy, path replaced by a different file | Copy preserved. |
| 1.3.5 | Legacy copy unreadable | Copy preserved (unverifiable ⇒ keep). |
| 1.3.6 | Path-only member, path resolves | Bookmark created with legacy-unverified provenance. |
| 1.3.7 | Path-only member, path does not resolve | Searchable unavailable reference, **no** bookmark. |
| 1.3.8 | **(must not) auto-bind** | For 1.3.7, later create a file at that exact path. The entry **(must not)** bind to it. |
| 1.3.9 | Mixed collection | One entry mixing ordinary, legacy-unverified, unavailable, and owned members renders and lists all members in order. |
| 1.3.10 | No discard confirmation | Migration keeps unresolvable records without prompting. |

### 1.4 Restore File… / Restore Files…

| # | Case | Pass |
| --- | --- | --- |
| 1.4.1 | Single owned member | Restore writes to a user-chosen destination; the member converts to an ordinary reference in one transaction. |
| 1.4.2 | Multiple owned members | All destinations chosen, all bookmarks created, then **one** transaction converts all. |
| 1.4.3 | **Partial failure** | Make one destination unwritable. No encrypted payload is retired; history state stays retryable; already-written output files may remain. Retrying succeeds. |
| 1.4.4 | Restore does not rewrite identity | Capture-time paths and the duplicate fingerprint are unchanged after restore. |

### 1.5 Crash boundaries

| # | Case | Pass |
| --- | --- | --- |
| 1.5.1 | Force-quit **during** migration | Relaunch: history intact, migration retries and completes, no duplicates. |
| 1.5.2 | Force-quit **after publish, before cleanup** | Relaunch: no re-migration, no duplicates, snapshot removed. |
| 1.5.3 | Pre-publication failure | Legacy data left fully intact. |
| 1.5.4 | Plaintext cleanup | After success, no plaintext payloads remain; `grep -r` a canary across the store root returns nothing. |

---

## 2. Capture: observation and scheduling — P0

| # | Case | Pass |
| --- | --- | --- |
| 2.1 | ⌘C in native (TextEdit, Notes) | Captured; correct source app. |
| 2.2 | ⌘C in Electron (VS Code, Slack) | Same. |
| 2.3 | ⌘C in Terminal / iTerm | Same. |
| 2.4 | ⌘C in a browser | Same. |
| 2.5 | ⌘X | Captured. |
| 2.6 | Menu Edit → Copy (no keystroke) | Captured via the fallback tick. |
| 2.7 | Right-click → Copy | Captured. |
| 2.8 | Programmatic `pbcopy` | Captured. |
| 2.9 | Accessibility-driven copy | Captured. |
| 2.10 | **Rapid successive copies** | Three different values within 300ms — all three land. This is what the old plain poll missed. |
| 2.11 | **Generation change during read** | Copy a large value and immediately overwrite it mid-read. The pipeline retries rather than persisting a torn snapshot. |
| 2.12 | **Source precedence** | Copy, then immediately switch apps. Attribution is the app that owned the copy, not the newly focused one. |
| 2.13 | Baseline on enable | Turn Monitoring off, copy several values, turn it on. **(must not)** import anything from the off period. |
| 2.14 | Baseline on launch | Copy while AnyDoor is quit, then launch. **(must not)** import the pre-launch value. |
| 2.15 | Baseline after unlock | Lock screen, copy elsewhere, unlock. **(must not)** import from the locked period. |
| 2.16 | Baseline after migration | Migration completion establishes a new baseline, not a backfill. |
| 2.17 | Sleep / wake | Capture resumes after wake without relaunch. |
| 2.18 | **Self-writes** | Paste from history, copy a translation result, copy from translation history, screenshot auto-copy, Script Plugin `copy`, Port Manager copy, palette copy. **(must not)** create a history entry for any of them. |
| 2.19 | **Selected-text read** | Trigger translation of selected text (which synthesizes ⌘C internally). **(must not)** create a history entry, and the user's real clipboard is restored. |
| 2.20 | Excluded app | Apple Passwords and Keychain Access on a fresh install — nothing captured. |
| 2.21 | Exclusion migration | An existing install picks up the new defaults once. Remove one, relaunch — **(must not)** resurrect it. |
| 2.21a | Exclusion edits are live | Add an app via the picker and copy in it immediately — excluded without relaunch. Remove it and copy again — captured without relaunch. |
| 2.21b | Excluding does not delete | Adding an app to the list **(must not)** remove its existing history entries. |
| 2.22 | **Exclusion markers** | Each of `org.nspasteboard.ConcealedType`, `TransientType`, `AutoGeneratedType`, `com.agilebits.onepassword`, `net.antelle.keeweb`, `de.petermaurer.TransientPasteboardType`, `com.typeit4me.clipping`, `Pasteboard generator type` — discarded before payload bytes are read, and **(must not)** be overridable by settings. Real-world check: copy a password from 1Password. |
| 2.23 | Copy-only setting | With Copy-only on, ⌘X **(must not)** be captured while ⌘C is. |
| 2.24 | Universal Clipboard | Copy on iPhone. Captured, labeled without guessing device or app. |
| 2.25 | Ignore Universal Clipboard | Turning it on stops **future** ones only; existing entries stay. |

**Budget** — copy to visible in the wall: ⌘C/⌘X assisted **< 250ms**;
fallback path (menu copy, programmatic) **< 800ms**.

### 2.26 Source attribution ladder — P1

Attribution is a strict priority ladder, not a guess. Test each rung in
isolation, because a lower rung silently taking over is invisible in normal use.

| Priority | Provenance | Trigger | Case |
| --- | --- | --- | --- |
| 1 | *(exclude)* | An exclusion marker is advertised | Wins over everything below, including Universal Clipboard |
| 2 | `universalClipboard` | The Universal Clipboard type is advertised | Labeled as such, **(must not)** guess a device or app |
| 3 | `declared` | The app declares its own source bundle ID on the pasteboard | The **declared** ID wins over the frontmost app |
| 4 | `copyEvent` | Frontmost app at the ⌘C/⌘X hint | Normal case |
| 5 | `observation` | Frontmost app at the poll tick | Menu copy, `pbcopy` |
| 6 | `unknown` | Nothing resolvable | Rendered cleanly, still filterable |

| # | Case | Pass |
| --- | --- | --- |
| 2.26.1 | Each rung above | Correct provenance and displayed app. |
| 2.26.2 | **Exclusion is checked against the resolved source** | An app that declares another app's bundle ID is excluded per the **declared** ID, not the real one. |
| 2.26.3 | `pbcopy` from Terminal | Attributed by observation, not left unknown. |
| 2.26.4 | Copy then instantly switch apps | The `copyEvent` rung holds; the newly focused app **(must not)** win. |
| 2.26.5 | Source filter counts | Each provenance groups under the right app in the ⌘K menu. |

---

## 3. Capture: supported content and limits — P0

| # | Case | Pass |
| --- | --- | --- |
| 3.1 | Exact plain text | Stored verbatim. |
| 3.2 | RTF / RTFD / HTML | All supplied rich representations stored; pasting into a rich target preserves formatting. |
| 3.3 | URL + exact text | Both stored. |
| 3.4 | Standard color | Stored plus its normalized form. |
| 3.5 | Still bitmap | One orientation-applied lossless PNG. An EXIF-rotated JPEG pastes upright. |
| 3.6 | Concrete `file://` URLs | Stored as references (see section 5). |
| 3.7 | **Application-private data** | **(must not)** be stored. |
| 3.8 | **Unknown binary format** | **(must not)** be stored. |
| 3.9 | **PDF-only clipboard data** | **(must not)** be stored. Copy a page in Preview — verify the behaviour is a clean skip, not a broken entry. |
| 3.10 | **File promises** | **(must not)** be materialized or stored. Drag-copy from an app that promises files. |
| 3.11 | Private type alongside supported data | The private type is ignored; the item is still stored. |
| 3.12 | **Unsupported-only item in a multi-item state** | The **complete** state is skipped. **(must not)** silently store a shortened version. |
| 3.13 | Zero-length string | Absent from history. |
| 3.14 | Whitespace-only | **Present**, preserved exactly (spaces, tabs, CRLF vs LF). |
| 3.15 | Multi-item order | Copy several items at once; item boundaries and order survive a normal paste. |
| 3.16 | Normal paste fidelity | Every stored representation and item is restored in order. |
| 3.17 | Plain-text paste availability | Offered only when **every** item has exact text. For a mixed text+image entry it is unavailable rather than silently dropping the image. |

### 3.18 Hard limits (P0 — exact thresholds)

| # | Case | Pass |
| --- | --- | --- |
| 3.18.1 | Just under 128 MiB (`134_217_728` bytes) of canonical plaintext | Accepted. |
| 3.18.2 | Just over 128 MiB | **Complete entry rejected**, one non-modal notice. Existing history and the live pasteboard survive. |
| 3.18.3 | Just under 64,000,000 decoded pixels | Accepted. The cap is decimal, not `64 × 1024²`: 8000×8000 is exactly at it, so test 7900×8000 (accept) and 8100×8000 (reject). |
| 3.18.4 | Just over 64,000,000 pixels | Rejected the same way. |
| 3.18.5 | Aggregate across a multi-item entry | The limits are aggregate, not per item. A state of many items summing past a limit is rejected whole. |
| 3.18.6 | Repeated rejections | Notices are rate-limited to one, not a stream. |

### 3.19 Every rejection reason — P0

`ClipboardHistoryCaptureRejection` has exactly seven cases. Each must be
reachable and must reject the **complete** observed state, never a partial one.

| # | Reason | How to trigger | Pass |
| --- | --- | --- | --- |
| 3.19.1 | `excluded` | Copy in an excluded app, or with an exclusion marker present | Nothing stored, no notice needed |
| 3.19.2 | `empty` | Copy a zero-length string | Nothing stored |
| 3.19.3 | `unsupportedItem` | Copy PDF-only from Preview | Whole state skipped (see 3.12) |
| 3.19.4 | `generationChanged` | Overwrite the pasteboard mid-read | Retried, not persisted torn |
| 3.19.5 | `contentTooLarge` | See 3.18.2 | Rejected with one notice |
| 3.19.6 | `imageTooLarge` | See 3.18.4 | Rejected with one notice |
| 3.19.7 | **`invalidFileReference`** | Put a `file://` URL on the pasteboard that cannot produce a bookmark — a path deleted between the copy and the read, or one AnyDoor cannot reach | **The complete entry is rejected**, not stored as a path-only reference. Verify the live pasteboard and existing history are untouched. |

Case 3.19.7 is the one worth real effort: it is a race, and the rejection is
whole-entry. Copying a file and deleting it immediately is the practical
reproduction.

### 3.20 Duplicates and recapture — P0

The most-used behaviour in any clipboard manager, and the easiest to break:
identity is a fingerprint plus canonical byte count, **re-verified** against the
full canonical identity, and only live entries are reuse candidates.

| # | Case | Pass |
| --- | --- | --- |
| 3.20.1 | Copy the same text twice | **One** entry, moved to the top. **(must not)** create a second row. |
| 3.20.2 | Copy A, B, A | Two entries; A is on top with an updated capture time. |
| 3.20.3 | Recapture updates retention | A's retention window restarts (see 9.11). |
| 3.20.4 | Recapture from a different app | Source attribution reflects the new capture. |
| 3.20.5 | **Same plain text, different representations** | Copy `hello` as plain text from Terminal, then as styled text from Pages. Canonical identity differs → **two** entries, not a merge. |
| 3.20.6 | Recapture after expiry | Let A expire, then copy A again. A **new** entry, not a resurrected one. |
| 3.20.7 | Recapture of a protected entry | A favorited old entry is still a reuse candidate even past its window. |
| 3.20.8 | Identical image copied twice | One entry. Verify only one payload file exists on disk. |
| 3.20.9 | **(must not)** merge on fingerprint alone | Recapture must survive the full identity re-verification; two entries with equal size but different content stay separate. |
| 3.20.10 | Recapture grants a fresh OCR budget | See 6.12. |

---

## 4. Content classification (facets) — P1

Facets are overlapping, not an enum. These inference rules are exactly the
kind that drift; test the negatives.

### 4.1 Link

| Input | Result |
| --- | --- |
| `https://example.com/a` | Link |
| `http://example.com` | Link |
| `example.com` (bare host) | Link |
| `localhost:3000` | Link |
| `192.168.1.1` | Link |
| `2001:db8::1` (IPv6 host) | Link |
| `raycast://extensions/x` (valid deep link) | Link |
| `tel:+15551234` (**scheme without `://`**) | **no Link** |
| `/Users/me/file.txt` (leading slash) | **no Link** |
| `file:///Users/me/x` | **File** facet, **no Link** |
| `example..com` / `.example.com` / `example.com.` | **no Link** (malformed labels) |
| `https://{{host}}/x` (template) | **no Link** |
| `https://a.com /b` (internal whitespace) | **no Link** |
| `javascript:alert(1)` | **no Link** |
| `data:text/html,<b>x` | **no Link** |
| `vbscript:msgbox` | **no Link** |
| `see https://example.com here` (embedded) | **no Link** — stays searchable Text |

### 4.2 Email

| Input | Facets |
| --- | --- |
| `me@example.com` | Text + Email |
| `mailto:me@example.com` | Text + Email + Link |
| `Me <me@example.com>` (display name) | Text only |
| `a@x.com, b@y.com` (list) | Text only |

### 4.3 Color

| Input | Color? |
| --- | --- |
| Explicit pasteboard color (system picker) | yes |
| `#F00`, `#F00A` (3- and 4-digit) | yes |
| `#FF0000`, `#FF0000AA` (6- and 8-digit) | yes |
| `rgb(255, 0, 0)` and `rgb(255 0 0 / 0.5)` (both syntaxes) | yes |
| `hsl(0, 100%, 50%)` and `hsl(0deg 100% 50% / 50%)` | yes |
| AnyDoor SwiftUI form | yes |
| `#FF000` (5 digits) / `#FF00000` (7 digits) | **no** |
| `FF0000` (bare hex, no `#`) | **no** |
| `red` (name) | **no** |
| `var(--brand)` | **no** |
| `linear-gradient(...)` | **no** |
| `color(display-p3 1 0 0)` (extended function) | **no** |
| `rgb(255, 0, 0) ` with trailing text or newline | **no** (anchored match) |

### 4.4 Image and Screenshot

| # | Case | Pass |
| --- | --- | --- |
| 4.4.1 | Any bitmap | Image facet. |
| 4.4.2 | AnyDoor's own capture | Image **+** Screenshot. |
| 4.4.3 | **(must not)** heuristics | Copy an external image named `Screenshot 2026-07-30 at 10.00.00.png`, with screen-sized dimensions, from an app called "Screenshot". It gets Image only — **never** Screenshot. |

### 4.5 Derived values do not recurse

| # | Case | Pass |
| --- | --- | --- |
| 4.5.1 | Image whose OCR text contains a URL | The entry **(must not)** gain Link. |
| 4.5.2 | QR encoding an email address | The entry **(must not)** gain Email. |
| 4.5.3 | QR encoding a hex color | The entry **(must not)** gain Color. |

### 4.6 Filter behaviour

| # | Case | Pass |
| --- | --- | --- |
| 4.6.1 | Facet filter is single-select with All, fixed order | Confirmed. |
| 4.6.2 | Source, tag, favorites-only are separate AND constraints | Combining them narrows, never widens. |

---

## 5. File references — P1

| # | Case | Pass |
| --- | --- | --- |
| 5.1 | Copy one file in Finder | Reference stored with encrypted path, name, order, bookmark. |
| 5.2 | Copy multiple files | All members, order preserved. |
| 5.3 | **No content copy** | `du -sh` the store root before/after copying a 5GB file. Growth is negligible — **(must not)** copy bytes. |
| 5.4 | **Rename** the file | Entry still resolves and pastes (bookmark follows the rename). |
| 5.5 | **Move** the file on the same volume | Still resolves. |
| 5.6 | **(must not) rebind** | Delete the referenced file, then create a *different* file at the old path. The entry **(must not)** resolve to the new file. |
| 5.7 | Unavailable member — searchable | The entry still appears in search by name and path. |
| 5.8 | Unavailable member — blocks paste | Normal paste of the complete entry is blocked and the **missing count** is reported. |
| 5.9 | Mixed entry with one missing member | Same: blocked with a count, not a partial paste. |
| 5.10 | External volume | Copy from a USB/network volume, eject it. Entry stays searchable; **(must not)** mount the volume to resolve. |
| 5.11 | Directory reference | Behaves as a reference; contents never copied. |
| 5.12 | Referenced image file | Gains Image via declared type metadata, but **(must not)** be opened for OCR or QR. |
| 5.13 | Unicode / very long filenames | Stored and displayed correctly. |

---

## 6. Derived text: OCR and QR — P1

| # | Case | Pass |
| --- | --- | --- |
| 6.1 | Indexing **off** (default) | Copy an image of text. Its text is **not** searchable. |
| 6.2 | Turn indexing **on**, then copy | Text becomes searchable once the job finishes. |
| 6.3 | **No backfill** | Enabling **(must not)** index images captured before it was enabled. |
| 6.4 | Disable with jobs pending | Already-pending jobs finish; their text is retained. New captures are not eligible. |
| 6.5 | Disable retains indexed text | Previously indexed text stays searchable. |
| 6.6 | QR is always on | Copy an image containing a QR code with indexing off — its value is still indexed. |
| 6.7 | QR has no setting | Confirm no toggle exists for it. |
| 6.8 | **No sibling entry** | Neither OCR nor QR creates a second history record, and normal image paste is unchanged. |
| 6.9 | Both attach to one entry | An image with text *and* a QR code — both attach to the same entry. |
| 6.10 | Retry budget | An image that fails recognition retries up to three attempts total, then fails silently (no error UI). |
| 6.11 | Empty result does not retry | An image with no text yields no repeated attempts. |
| 6.12 | Duplicate recapture grants a fresh budget | Re-copy an image whose jobs were exhausted; recognition is attempted again. |
| 6.13 | Persists across relaunch | Copy several images, quit before jobs finish, relaunch. Jobs resume. |
| 6.14 | **(must not)** touch file references | See 5.12. |

---

## 7. Search and pagination — P1

| # | Case | Pass |
| --- | --- | --- |
| 7.1 | Empty query | Strictly newest first. |
| 7.2 | Case | `SWIFT` finds `swift`. |
| 7.3 | Diacritics | `cafe` ⇄ `Café` ⇄ `Cafe` + combining accent. |
| 7.4 | Full width | `full-width` finds `Ｆｕｌｌ－Ｗｉｄｔｈ`. |
| 7.5 | **1-character CJK** | `甲` returns complete results, not partial. |
| 7.6 | **2-character CJK** | `乙丙` likewise. |
| 7.7 | 3+ character CJK | `剪贴板` likewise. |
| 7.8 | Emoji | `🚀` found. |
| 7.9 | RTL text | Arabic/Hebrew content is searchable and renders correctly. |
| 7.10 | Multi-word AND | `swift actor` returns only entries with both. |
| 7.11 | Word order irrelevant | `actor swift` returns the same set. |
| 7.12 | **Ranking** | Exact whole-field > prefix > mid-string substring. |
| 7.13 | **Field priority** | Copied text > OCR text > file paths, for equal match class. |
| 7.14 | Multi-item fields | A term in the second item of a multi-item entry matches the entry. |
| 7.15 | Searches OCR, QR, filenames, both paths, normalized colors | Each independently verified. |
| 7.16 | **FTS syntax is literal** | `AND`, `OR`, `NOT`, `NEAR`, `"`, `*`, `(`, `^`, `-` are all treated as text. None errors; none acts as an operator. |
| 7.17 | Filters are not searchable text | Searching an app name **(must not)** match by source; source is a filter. |
| 7.18 | No results | Clean empty state. |
| 7.19 | Pagination | Scroll past 100. No duplicates, no gaps, no scroll jump. |
| 7.20 | **Cursor invalidation** | Load page 2, then change the query. Pagination restarts; **(must not)** mix generations. |
| 7.21 | **Index-generation change mid-paging** | Load page 2, delete an entry (mutating the index), then load more. Restarts cleanly rather than mixing. |
| 7.22 | Stale token rejected | Reuse an old cursor after a filter change — rejected, not honoured. |
| 7.23 | Search during rebuild | Force a rebuild (delete the FTS tables, relaunch). Browsing works; search shows an **indexing** state, **(must not)** show incomplete results. |
| 7.24 | Rebuild failure | Make the rebuild fail. Search reports failure rather than falling back to a linear scan. |
| 7.25 | Combined filters | Query + facet + source + tag + favorites, all at once. |
| 7.26 | Clearing the query | Returns to newest-first with no perceptible delay. |

---

## 8. Performance, latency, and stutter — P1

The section that decides whether the rewrite was worth it. Run every case at
**three volumes — 1000, 10000, 50000 entries** — and record each. A budget
that holds at 1000 and breaks at 10000 is a failure. Re-measure on the Intel
machine from 0.1.

### 8.1 Search typing latency — headline case

**Steps.** Type `swift` one character at a time at ~100ms intervals. Then hold
backspace to clear.

**Pass.** The text field never lags behind the keyboard.

**Budget** — results settle after typing stops:

| Volume | Budget |
| --- | --- |
| 1000 | < 150ms |
| 10000 | < 300ms |
| 50000 | < 600ms |

### 8.2 The four query shapes the contract names

Measure first-page latency **and** peak memory for each, at each volume:

| Shape | Example | Note |
| --- | --- | --- |
| Empty | `` | Pure browse path, should be near-constant |
| One character | `e`, `的` | Worst case — matches nearly everything |
| Two characters | `sw`, `乙丙` | Uses the short-gram index, not trigram |
| Long substring | a 40-character phrase | Trigram phrase, few matches |

**Pass.** All four stay within the 8.1 budget. Memory does not spike with match
count — a one-character query at 50000 entries **(must not)** balloon the
footprint.

### 8.3 Copy while searching — actor contention

**Steps.** Start a broad query; while results load, copy in another app.

**Pass.** The copy is captured within the section 2 budget. Search and capture
share the module actor; a long search blocking capture is the specific
regression this rewrite exists to prevent.

### 8.4 Wall open latency

| Case | Budget |
| --- | --- |
| Cold (first open after launch) | < 400ms to first painted row |
| Warm | < 150ms |
| At 50000 entries | Same — page size is fixed at 100, so volume must not matter |
| Global hotkey → visible | < 400ms end to end |

**Pass.** The window appears already populated. An empty frame followed by rows
popping in is a failure.

### 8.5 Paste latency

**Steps.** Open the wall, select an entry, press Return. Measure to content
landing in the target app.

| Entry type | Budget |
| --- | --- |
| Plain text | < 200ms |
| Rich text / multi-representation | < 300ms |
| Large image (30MB) | < 800ms, no beachball |
| File reference | < 200ms |

**Pass.** Focus returns to the target app correctly; the paste lands in the
right place.

**Preview is a different path.** A preview resolves only the thumbnail payload
(see 11.21.3), so previewing a 50MB image must be **< 100ms** and must not move
memory. If preview latency tracks image size, the thumbnail short-circuit is
not being taken.

### 8.6 Live updates while the wall is open

**Steps.** Open the wall. Copy several values in another app while it stays
open. Then repeat while scrolled halfway down, and again with an active search
query.

**Pass.** New entries appear without the list jumping, without losing the
user's scroll position, and without stealing selection. With a query active,
a new non-matching entry **(must not)** appear.

**Budget.** No visible hitch when an entry is inserted. Copying an image while
the wall is open **(must not)** stall the list while its thumbnail is produced.

### 8.7 Scrolling

**Steps.** Scroll top to bottom through several pages including a run of image
entries.

**Budget.** Zero hitches over 5s of continuous scrolling in Instruments →
Animation Hitches. Thumbnails appear within 200ms of a row becoming visible.

**Why it can fail.** Every thumbnail is individually AES-GCM encrypted;
decrypting on the main thread during scroll is visible.

### 8.8 Large payloads and fingerprinting

| Case | Pass |
| --- | --- |
| Copy a 50MB image | Captured; UI responsive during encryption **and** duplicate fingerprinting. |
| Copy a 60-megapixel image (just under the cap) | Captured within 2s; no beachball. |
| Copy a 100MB text blob | Captured or cleanly rejected per 3.18. |
| Copy 500 files at once | Handled or cleanly rejected; no freeze. |

**Budget.** The menu bar item responds to a click within 200ms at all times,
including mid-capture. Fingerprinting a large image **(must not)** block the
main thread.

### 8.9 Consecutive-copy loss rate

The PRD requires this benchmarked separately for event-assisted bursts, because
it is the whole justification for the ⌘C/⌘X hint path.

**Steps.** Copy N distinct values as fast as a human realistically can (≈150ms
apart), by hand in a real app — not via `pbcopy`, which bypasses the key hint.
Do 50 copies. Then repeat via menu Edit → Copy (fallback path only).

**Pass.** Count the entries that landed.

| Path | Budget |
| --- | --- |
| Event-assisted (⌘C) | Zero loss at 150ms spacing |
| Fallback (menu copy) | Loss only where two copies fall inside one 500ms idle tick |

`monitorMetrics().overwrittenGenerationCount` is the exact loss counter; see
the probe note in 8.11. Compare against a `main` build to prove the hint path
is an improvement rather than a wash.

### 8.10 Sustained copy load

```bash
for i in $(seq 1 500); do printf 'load %d\n' "$i" | pbcopy; sleep 0.05; done
```

**Pass.** Every value captured. The wall stays usable during the run. CPU
returns to idle within 5s of the loop ending.

**Budget.** AnyDoor stays under 30% of one core during the run.

### 8.11 Idle cost — explicit contract gate

The PRD requires the idle fallback to produce **no more than two timer fires
per second** and permits **no material regression** in wakeups, CPU, or Energy
Impact versus the old plain 500ms poll.

**Steps.** Leave the Mac idle with AnyDoor running and no copying for **10
minutes**. Record:

```bash
sudo powermetrics --samplers tasks -n 1 | grep -i anydoor   # wakeups/sec, CPU ms/s
```

Also record Activity Monitor → Energy → *Energy Impact* and *Avg Energy
Impact*. Run the identical trial against a `main` build; the comparison is the
gate, absolute numbers alone are not.

**Budget.**

| Metric | Budget |
| --- | --- |
| Idle timer fires | ≤ 2/sec (the scheduler's idle interval is 500ms) |
| Idle CPU | < 0.5% average over 10 minutes |
| Wakeups | No material increase versus `main` measured the same way |
| Energy Impact | Same |

**Exact counts.** `ClipboardHistoryModule.monitorMetrics()` returns
`idleTimerFireCount`, `boostedTimerFireCount`, `observedChangeCount`,
`capturedChangeCount`, and `overwrittenGenerationCount` — precisely what this
gate needs. It has **no shipped surface**: nothing in the app or its logs reads
it. Reaching it requires a temporary env-gated probe (the pattern already used
for capture verification). Treat the absence of a surface as a finding, not a
test-plan problem: this gate must be re-verifiable on a release build.

**Boost windows.** After a ⌘C hint the scheduler polls at 50ms for 500ms; after
an observed change, at 100ms for 500ms. Confirm both windows actually expire:
copy once, then idle for 5s and check that fires return to the idle rate rather
than staying boosted.

**Also.** Repeat with the display asleep and after a lid close/open. The timer
must **stop** while monitoring is off, during sleep, and while the screen is
locked — verify it stops rather than merely discarding results.

**Why this matters.** This is a menu-bar app that runs all day on battery. A
regression here is invisible in every other case in this plan.

### 8.12 Migration cost

**Budget** — 5000 entries / ~1GB of payloads:

- Completes within **60s**.
- Peak `phys_footprint` under **1.5×** the legacy store's own size. (The
  automated measurement was 113MB for 800 × 128KB rows.)
- The menu bar item stays responsive; no beachball.
- Settings → Clipboard shows a migrating state, not an empty history.
- Opening the wall mid-migration shows a sensible state rather than hanging.

### 8.13 Search index rebuild

**Steps.** Delete the FTS tables at 50000 entries and relaunch.

**Budget.** Browsing is available immediately. Rebuild completes within **120s**
and does not block the UI. CPU stays under one core.

### 8.14 Retention cleanup with secure delete

**Steps.** At 50000 entries, shorten retention from Unlimited to 7 days.

**Budget.** Affected count computed within **2s**. UI stays responsive during
deletion. Note that both FTS tables run FTS5 `secure-delete=1` on top of
`PRAGMA secure_delete=ON`, so this is deliberately the most expensive delete
path — measure it rather than assuming.

### 8.15 Memory

| Checkpoint | Budget |
| --- | --- |
| Idle, wall closed, 10000 entries | < 150MB |
| Wall open, scrolled through 500 image rows | < 400MB peak |
| Settled 30s after closing | Near idle |

Repeat open/scroll/close **ten times**; the settled figure **(must not)** drift
upward.

### 8.16 Disk growth

**Pass.** Growth is proportional to what was stored. Settings → Clipboard's
reported usage matches `du -sh` within a few percent, and **includes**
encrypted orphans. WAL does not grow without bound across a long session —
check it after 8.10.

### 8.17 Launch impact

**Budget.** At 50000 entries, launch to a clickable menu bar item in **< 1.5s**.
The store opens synchronously in `AppDelegate.init`; an integrity check over a
large trigram index is the thing to watch.

---

## 9. Retention, protection, deletion — P1

| # | Case | Pass |
| --- | --- | --- |
| 9.1 | Every preset | 1d, 7d, 30d, 3mo, 6mo, 1y, Unlimited all selectable and enforced. |
| 9.2 | **(must not)** hidden limits | At 50000 entries with Unlimited, nothing is evicted by count, disk, or LRU. |
| 9.3 | Shorten with affected entries | Exact count shown; confirmation required; period and deletion commit atomically. |
| 9.4 | Shorten with zero affected | Applies immediately, no prompt. |
| 9.5 | Count changes during the prompt | Prompt refreshes rather than committing a stale count. |
| 9.6 | Favorite protection | An old favorited entry survives indefinitely. |
| 9.7 | Tag protection | Same for a tagged entry. |
| 9.8 | Losing last protection | Unfavorite an old protected entry → fresh retention window, **(must not)** vanish immediately. |
| 9.9 | Deleting a tag definition | Membership removed; entries losing last protection get a fresh window. |
| 9.10 | Importing away a tag | Same via a config import. |
| 9.11 | Retention start on capture | New capture and real duplicate recapture both set it. |
| 9.12 | Retention start on edit | Editing text resets it **without** changing recency. |
| 9.13 | Expired entries | Gone from wall, search, counts, and duplicate reuse simultaneously. |
| 9.14 | **(must not)** resurrect | After expiry, set a longer period. The entries stay gone. |
| 9.15 | Physical reclamation | Encrypted storage reclaimed within 24h by the maintenance loop. |
| 9.15a | **Deadline is persisted** | The next-maintenance deadline lives in the database, not in memory. Quit and relaunch several times inside one 24h window — **(must not)** restart the clock each launch, or a user who quits daily never gets maintenance at all. |
| 9.15b | **Missed deadline** | Quit across the deadline (move the system clock forward a day with the app closed). Maintenance runs promptly after the next launch. |
| 9.15c | **Failure backoff** | Make maintenance fail (read-only store directory). Retries back off 5min → doubling → **60min cap**, and **(must not)** spin. Check idle CPU per 8.11 while it is failing. |
| 9.15d | Recovery | Remove the cause; the next retry succeeds and the 24h cadence resumes. |
| 9.16 | Clear History, default scope | Confirms; protected entries survive; tag definitions, settings, and the live pasteboard survive. |
| 9.17 | Clear History, including protected | Checkbox updates the count and removes everything. |
| 9.18 | **Usage is not capture** | Preview, copy, and paste an old entry. It **(must not)** move to the top, change source attribution, or extend retention. |

---

## 10. Encryption and privacy — P0

| # | Case | Steps | Pass |
| --- | --- | --- | --- |
| 10.1 | **No plaintext at rest** | Copy `CANARY-8f3a2b`, then `grep -r` the whole store root including `-wal`. | No match. |
| 10.2 | Payload envelope | `xxd` the newest file under `payloads/`. | Starts with `ADCHPAYL`, not PNG/JPEG magic. |
| 10.3 | No plaintext in temp | Repeat 10.1 against `/tmp`, `$TMPDIR`, `~/Library/Caches`. | No match. |
| 10.4 | Nothing in logs | `log show --last 10m --predicate 'subsystem == "dev.bybee.AnyDoor"'`. | Content, paths, search terms, recognized values never appear. |
| 10.5 | Search terms not cached | Search the canary, quit, grep the store root and caches. | No match. |
| 10.6 | Keychain locked | Lock the login keychain, copy, unlock. | Capture pauses; resumes from a new baseline. |
| 10.7 | **Key missing** | Delete the Keychain item. Launch. | Store Unavailable with retry and a confirmed reset. **(must not)** silently replace or wipe the database. |
| 10.8 | Wrong key | Restore a store from a machine with a different key. | Clean authentication failure, no reset. |
| 10.9 | Reset action | Use the confirmed Reset. | History cleared, new key, app works. |
| 10.10 | Backup excludes history | Export a backup from Settings → Sync; inspect it. | No entries, no keys, no exclusion-list contents. |
| 10.11 | Sync excludes history | Inspect the sync state file. | Same. |
| 10.12 | Keychain item not synced | Verify the item is device-only in Keychain Access. | Not in iCloud Keychain. |
| 10.13 | Cross-identity | Follow `docs/testing/clipboard-history-keychain-integration.md`. | Documented behaviour holds; no silent loss. |

---

## 11. UI and interaction — P1

| # | Case | Pass |
| --- | --- | --- |
| 11.1 | Wall keyboard nav | Arrows, Home/End, Return to paste, Esc to dismiss. |
| 11.2 | Facet filter | All eight facets plus All; single-select; fixed order. |
| 11.3 | Source filter | ⌘K opens the menu; counts match; a removed source clears the filter. |
| 11.4 | Tags | Create, rename, delete, assign, unassign; order persists across relaunch. |
| 11.5 | Category reordering | Reorder categories; persists. |
| 11.6 | Favorites | Toggle from wall and popover. |
| 11.7 | Text editing — availability | Offered **only** for a one-item exact-text entry. Not offered for image, file, or multi-item entries. |
| 11.8 | Text editing — identity | Id, source, capture time, favorite, tags survive; recency does not move. |
| 11.9 | Text editing — provenance drop | Editing drops stale rich/URL/color/QR provenance; the entry becomes plain text. |
| 11.10 | Zero-length edit rejected; whitespace-only accepted | Confirmed. |
| 11.11 | Edit updates search transactionally | New text searchable, old text no longer matches. |
| 11.12 | **(must not)** auto-merge | Edit an entry to equal another entry's content. They stay separate. |
| 11.13 | Quick Look | Opens for image and file entries; closes cleanly. |
| 11.14 | Paste targets | Plain text, rich text, image, and file targets each receive the right representation. |
| 11.15 | Plugin context actions | Convert Image appears only while the Image Conversion plugin is installed, and acts on the right entry. |
| 11.16 | Menu-bar popover | Lists, filters, and pastes correctly. |
| 11.17 | Localization | 简体中文 and English; no raw keys; new strings translated. |
| 11.18 | Empty states | Fresh install / no results / filtered-to-empty are each distinct and sensible. |
| 11.19 | Error surface | One rate-limited error, not a stream of alerts. |
| 11.20 | Reduce Motion | With Reduce Motion on, the wall still opens and scrolls correctly. |

### 11.21 Materialization purposes

One entry is materialized four different ways. Each path has its own
short-circuit, so each needs its own case.

| # | Purpose | Path | Pass |
| --- | --- | --- | --- |
| 11.21.1 | `normalPaste` | Return in the wall | Every representation and item, in order. |
| 11.21.2 | `plainTextPaste` | The plain-text variant | Only when every item has exact text (see 3.17). |
| 11.21.3 | **`preview`** | Hover/preview in the popover | Resolves the **thumbnail** payload only. Preview a 50MB image and confirm the full payload is never decrypted — this is a latency and memory path, not just a display one. |
| 11.21.4 | `preview` with no thumbnail | A text entry | Falls through to normal materialization without erroring. |
| 11.21.5 | **`hostAction`** | A plugin clipboard action (Convert Image) | Receives the full payload; the plugin acts on the right entry. |
| 11.21.6 | **Expired entry** | Keep the wall open past an entry's retention expiry, then paste it | Clean "not found" handling. **(must not)** crash or paste stale content. |

---

## 12. Failure and recovery — P0

| # | Case | Pass |
| --- | --- | --- |
| 12.1 | Corrupt database | Store Unavailable with retry and confirmed reset. **(must not)** silently recreate. |
| 12.2 | Disk full during capture | New entry rejected; existing history and the live pasteboard survive; one rate-limited error. |
| 12.3 | Corrupt single payload | Only that entry's payload action is disabled; everything else works. |
| 12.4 | Kill mid-capture | **(must not)** leave a committed reference to an unfinished file. At worst an encrypted orphan, counted in storage usage. |
| 12.5 | Orphan reconciliation | After 12.4, orphans are reclaimed and the reported usage drops. |
| 12.6 | Read-only store directory | Clear failure, no crash, no data loss when permissions are restored. |
| 12.7 | Missing payload file | That entry degrades gracefully; the list still renders. |
| 12.8 | Kill during retention deletion | Relaunch is consistent; no half-deleted entries. |
| 12.9 | Kill during index rebuild | Rebuild resumes; browsing available. |
| 12.10 | Clock moved backward a day | No entries vanish; retention does not misfire. |
| 12.11 | Clock moved forward a year | Expiry behaves per the configured period, not catastrophically mid-session. |

### 12.12 Every lifecycle state — P0

`ClipboardHistoryLifecycleState` has seven cases. Each renders somewhere in
Settings → Clipboard and in the wall, and three of them are dead ends if the
recovery affordance is wrong.

| # | State | How to reach it | Pass |
| --- | --- | --- | --- |
| 12.12.1 | `preparing` | Launch with a large store | Transient, not a stuck spinner. |
| 12.12.2 | `migrating` | Section 1 | Distinct from an empty history. |
| 12.12.3 | `ready` | Normal | — |
| 12.12.4 | **`paused`** | Lock the login keychain | **Self-recovering**: unlocking resumes without relaunch and without a reset prompt. Must read as temporary, not broken. |
| 12.12.5 | **`storeUnavailable`** | Corrupt the database, or delete the Keychain item | Requires action: retry **and** a confirmed reset. Never self-heals by wiping. |
| 12.12.6 | **`migrationFailed`** | Make the migration fail (unwritable target directory) | Legacy data intact, a retry path exists, and the app is still usable for everything else. |
| 12.12.7 | **`resetFailed`** | Make the confirmed reset itself fail (read-only store directory) | **Not a dead end**: the state is reported, retry is possible, and the app does not loop the reset dialog. |

The `paused` ⇄ `storeUnavailable` distinction is the one to get right — a
temporary keychain lock presented as "your history is unavailable, reset?" will
cause a user to wipe their own data.

### 12.13 Search index failure reasons

| # | Reason | Pass |
| --- | --- | --- |
| 12.13.1 | `rebuildFailed` | Reported as a search failure; browsing still works; **(must not)** fall back to a linear scan. |
| 12.13.2 | `stateUnavailable` | Distinguished from a rebuild failure, with its own message. |
| 12.13.3 | `retrySearchIndex()` | The retry affordance actually re-attempts and recovers when the cause is removed. |

---

## 13. Environment matrix — P1

| # | Case | Pass |
| --- | --- | --- |
| 13.1 | Two displays | The wall opens on the active display, fully on-screen. Note: the status item can sit on a left-hand display at negative x. |
| 13.2 | Mixed scale factors | Retina + non-Retina; thumbnails are crisp on both, no layout break. |
| 13.3 | Display disconnected while the wall is open | The wall moves or closes; **(must not)** be stranded off-screen. |
| 13.4 | **Concurrent identities** | Run `swift run AnyDoor` while the installed app is running. Neither corrupts the store; SQLite locking behaves. Document what actually happens. |
| 13.5 | Sparkle update relaunch | Update while running; the store reopens cleanly after relaunch. |
| 13.6 | Login auto-launch | **(must not)** show any window on login. |
| 13.7 | Locale change | Switch system language and region; search normalization is unchanged (it is pinned to `en_US_POSIX`). |
| 13.8 | Time zone change | Timestamps and retention stay coherent. |
| 13.9 | Low disk (under 1GB free) | Capture degrades gracefully per 12.2. |
| 13.10 | FileVault on | No behavioural difference. |

---

## 14. Release acceptance gates — P1

Not runtime tests, but contract items that block acceptance.

- [ ] Universal build (`--arch arm64 --arch x86_64`) succeeds and the app runs
      on both architectures — this is the only place the x86_64 branches are
      exercised at runtime.
- [ ] **Release binary size impact measured and reported** versus the previous
      release (SQLCipher is a new dependency).
- [ ] `sqlcipher/GRDB.swift` and `sqlcipher/SQLCipher.swift` licenses present
      in `THIRD-PARTY-LICENSES.md`.
- [ ] SwiftPM pins match ADR-0013.
- [ ] `CHANGELOG.md` entry under `## [Unreleased]` matches shipped behaviour.
- [ ] No first-party build warnings (`swift build --build-tests` from clean).

---

## 15. Adjacent-feature regression sweep — P1

The branch touched 164 files.

- [ ] Global hotkeys fire; the event tap survives a search burst and a large capture
- [ ] Hyper Key unaffected
- [ ] Command Palette opens, searches, drills in
- [ ] Screenshot capture, annotation, scrolling capture; auto-copy lands in history exactly once
- [ ] Screen recording
- [ ] Translation, including copy-from-result and selected-text reading (see 2.19)
- [ ] Hosts plugin install/uninstall, including the privileged helper
- [ ] Image Conversion plugin and its clipboard context action
- [ ] Script Plugins, including a plugin's `copy` capability
- [ ] Config sync export/import round trip
- [ ] Settings: every tab opens; no focus loss on switch
- [ ] Scheduled Shutdown
- [ ] Sparkle update check
- [ ] Keyboard lock

---

## Reporting

For any failure record: case number, entry volume, machine and architecture,
the measured value against its budget, whether it reproduces, and a
`sample AnyDoor` trace for anything that stalls. A performance failure without
a number is not actionable.
