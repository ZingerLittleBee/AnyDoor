# Clipboard History v2 Manual Test Plan

The automated suite covers the store, the search index, migration boundaries,
and crash safety. It cannot cover what this feature is actually judged on:
whether copying feels instant, whether the wall opens without a hitch, and
whether a year of history still types smoothly. This plan covers that.

Scope: everything behind `docs/prds/2026-07-29-clipboard-history-v2.md`.

## How to read this

Each case has **Steps**, **Pass**, and where it matters a **Budget** — a number
that decides pass or fail. Budgets are not aspirations; a case that exceeds one
is a defect, not a note.

Priority markers:

- **P0** — must pass before merge. A failure here loses or exposes user data.
- **P1** — must pass before release. A failure here is a bad experience.
- **P2** — worth knowing. Record the result, decide separately.

## 0. Preparation

### 0.1 Builds

Test the **installed** app, not `swift run`. They are separate process
identities with separate Accessibility grants, and only the installed one has
the production Bundle ID that the Keychain item and the URL scheme key off.

```bash
make install          # /Applications/AnyDoor.app, Bundle ID dev.bybee.AnyDoor
```

Grant Accessibility to that binary specifically. Re-granting after a reinstall
is expected.

### 0.2 Store locations

```
~/Library/Application Support/dev.bybee.AnyDoor/AnyDoor.store        # SwiftData (no clipboard rows in v2)
~/Library/Application Support/dev.bybee.AnyDoor/ClipboardHistory/    # v2 store root
  history.sqlite, -wal, -shm                                          # SQLCipher
  payloads/                                                           # AES-GCM files
  staging/
~/Library/Application Support/dev.bybee.AnyDoor/ClipboardHistoryLegacyMigration/   # only mid-migration
~/Library/Application Support/dev.bybee.AnyDoor/ClipboardHistoryLegacyCutover-v1.complete
```

Keychain: one device-only generic-password item. Never synced, never in a
backup.

### 0.3 Building a large history

Perf cases need real volume. Do **not** hand-copy 10000 times. Two options:

**A. Drive real captures** (exercises the whole capture pipeline):

```bash
# 2000 mixed text entries, roughly one per 120ms.
for i in $(seq 1 2000); do
  printf 'fixture %d %s\n' "$i" "$(head -c 200 /dev/urandom | base64)" | pbcopy
  sleep 0.12
done
```

Vary it: include CJK, emoji, URLs, long code blocks, and periodic images
(`screencapture -c`).

**B. Disposable-home fixture** (fast, for migration cases):

```bash
CLIPBOARD_HISTORY_GUI_FIXTURE=1 CFFIXED_USER_HOME=/tmp/anydoor-fixture \
  swift test --filter ClipboardHistoryGUIFixtureTests/testCreateDisposableLegacyMigrationFixture
```

This writes a **legacy** store under a throwaway home. Use it to build
pre-v2 states without touching your real history.

### 0.4 Measuring

- **Latency you can feel** — screen-record at 60fps and count frames. One
  frame is 16.7ms; this is more honest than a stopwatch for anything under
  half a second.
- **Frame drops while scrolling** — Instruments → Animation Hitches, or
  Core Animation FPS. "Looks smooth" is not a result.
- **Memory** — Activity Monitor's *Memory* column tracks `phys_footprint`,
  which is what the OS kills on. Record idle, peak-while-scrolling, and
  settled-after.
- **Disk** — `du -sh` the store root before and after; compare against
  Settings → Clipboard's reported usage. They must agree.
- **Is it AnyDoor stalling or the target app?** — sample the process:
  `sample AnyDoor 3 -file /tmp/sample.txt` while reproducing.

### 0.5 Before each destructive case

```bash
cp -R ~/Library/Application\ Support/dev.bybee.AnyDoor /tmp/anydoor-backup-$(date +%s)
```

Several cases below deliberately corrupt or delete the store.

---

## 1. Migration from pre-v2 — P0

This path runs exactly once per user and has never been exercised on a real
install. It is the highest-risk area in the branch.

| # | Case | Steps | Pass |
| --- | --- | --- | --- |
| 1.1 | Fresh install | Remove the whole `dev.bybee.AnyDoor` directory. Launch. | Empty history, no error, no migration UI. Cutover marker present. |
| 1.2 | Small legacy store | Restore a pre-v2 store with ~50 entries. Launch. | Every entry present, same order, same favorites and tags. |
| 1.3 | Large legacy store | Pre-v2 store with 5000+ entries including images. Launch. | See Budget below. All entries migrate. |
| 1.4 | Legacy images and files | Pre-v2 store with owned image payloads and file entries. | Images render. File entries resolve or show a missing-file state, never a crash. |
| 1.5 | Legacy tags and favorites | Tag several legacy entries, favorite others. Launch. | Tags and favorites preserved; tag definitions intact; category order preserved. |
| 1.6 | Legacy retention setting | Set a non-default retention pre-v2. Launch. | The same preset is selected after migration. |
| 1.7 | **Kill mid-migration** | Launch with a large legacy store, force-quit during migration. Relaunch. | History intact. Migration retries and completes. No duplicates. |
| 1.8 | Kill after publish, before cleanup | Same, timed just after entries appear. Relaunch. | No re-migration, no duplicates, snapshot directory removed. |
| 1.9 | Second launch | Launch again after a successful migration. | No migration runs. Legacy snapshot directory absent. Marker present. |
| 1.10 | Plaintext cleanup | After 1.3 completes, inspect the old payload directory. | No plaintext payloads remain. `grep -r` a known copied secret across the store root returns nothing. |
| 1.11 | Corrupt legacy row | Hand-edit a legacy row to an unknown `ZKIND`. Launch. | That row is skipped; every other row migrates. Nothing fails wholesale. |

**Budget (1.3)** — first launch with 5000 entries / ~1GB of payloads:

- Migration completes within **60s**.
- Peak `phys_footprint` stays under **1.5x** the legacy store's own size.
- The menu bar item stays responsive throughout; the app never shows a
  beachball.
- Settings → Clipboard shows a migrating state rather than an empty history.

> The automated peak measurement was 113MB for 800 x 128KB rows. If a real
> store blows past the ratio above, capture a memory graph before filing.

---

## 2. Capture correctness — P0

| # | Case | Pass |
| --- | --- | --- |
| 2.1 | ⌘C in a native app (TextEdit, Notes) | Captured within budget, correct source app. |
| 2.2 | ⌘C in Electron (VS Code, Slack) | Same. |
| 2.3 | ⌘C in Terminal / iTerm | Same. |
| 2.4 | ⌘C in a browser (Safari, Chrome) | Same, with rich text preserved. |
| 2.5 | ⌘X | Captured. |
| 2.6 | Menu Edit → Copy, no keystroke | Captured via the polling fallback. |
| 2.7 | Right-click → Copy | Captured. |
| 2.8 | Programmatic `pbcopy` | Captured. |
| 2.9 | Copy an image (Preview, browser, `screencapture -c`) | Thumbnail renders; Image facet; Screenshot facet only for AnyDoor's own capture. |
| 2.10 | Copy one file in Finder | File facet, correct name, opens/reveals. |
| 2.11 | Copy multiple files | All members preserved, not collapsed to one. |
| 2.12 | Copy multiple pasteboard items at once | Multi-item entry preserved in full. |
| 2.13 | Copy rich text (Pages, Word, browser) | Rich representation retained; pasting into a rich target keeps formatting. |
| 2.14 | Copy a color from the system picker | Color facet, normalized hex searchable. |
| 2.15 | **Universal Clipboard** from iPhone | Captured, labeled without guessing the device. Turning on "Ignore Universal Clipboard" stops future ones only. |
| 2.16 | **Rapid successive copies** | Copy three different values within 300ms. All three land. This is the case the old 500ms poll missed. |
| 2.17 | **AnyDoor's own writes** | Paste from history, copy a translation, copy a screenshot, use a Script Plugin's `copy`. None of these create a new history entry. |
| 2.18 | Excluded app | Copy in Apple Passwords and in Keychain Access. Nothing captured, on a fresh install by default. |
| 2.19 | Exclusion marker | Copy from an app that sets `org.nspasteboard.ConcealedType`. Discarded before payload bytes are read. |
| 2.20 | Duplicate copy | Copy the same value twice. One entry, moved to top, not duplicated. Retention window resets. |
| 2.21 | Monitoring off | Turn off Monitoring, copy several values, turn it on. Nothing from the off period appears — no backfill. |
| 2.22 | Screen locked | Lock the screen, copy from another session path, unlock. Nothing captured while locked. |
| 2.23 | Sleep / wake | Sleep the Mac, wake, copy. Capture resumes without a relaunch. |

**Budget (2.1–2.8)** — copy to visible in the wall:

- With ⌘C/⌘X assistance: **under 250ms**.
- Via the polling fallback (menu copy, programmatic): **under 800ms**.

---

## 3. Search and filtering — P1

| # | Case | Pass |
| --- | --- | --- |
| 3.1 | Empty query | Strictly newest first. |
| 3.2 | Case insensitivity | `SWIFT` finds `swift`. |
| 3.3 | Diacritics | `cafe` finds `Café`; `café` finds `Cafe` + combining accent. |
| 3.4 | Full width | `full-width` finds `Ｆｕｌｌ－Ｗｉｄｔｈ`. |
| 3.5 | **1-character CJK** | `甲` finds every entry containing it. Complete, not partial. |
| 3.6 | **2-character CJK** | `乙丙` likewise. |
| 3.7 | 3+ character CJK | `剪贴板` likewise. |
| 3.8 | Emoji | `🚀` finds it. |
| 3.9 | Multi-word AND | `swift actor` returns only entries containing both. |
| 3.10 | Word order | `actor swift` returns the same set. |
| 3.11 | **Ranking** | An entry whose whole field equals the query ranks above a prefix match, which ranks above a mid-string match. |
| 3.12 | Field priority | Copied text outranks OCR text, which outranks file paths. |
| 3.13 | Search OCR text | With Image Text Indexing on, copy a screenshot of text, wait, search a word only present in the image. Found. |
| 3.14 | Search QR values | Copy an image of a QR code. Its decoded value is searchable. |
| 3.15 | Search file names and paths | Both capture-time and current path match. |
| 3.16 | **FTS syntax is literal** | Search `AND`, `OR`, `NOT`, `NEAR`, `"`, `*`, `(`, `^`. Each is treated as text; none errors, none behaves as an operator. |
| 3.17 | No results | Clean empty state, not a spinner. |
| 3.18 | Pagination | Scroll a result set past 100. More loads, no duplicates, no gaps, no jump. |
| 3.19 | Query change mid-scroll | Type while more is loading. Results restart cleanly, no mixed generations. |
| 3.20 | Combined filters | Query + facet + source + tag + favorites-only, all at once. AND semantics. |
| 3.21 | Search during index rebuild | Delete the FTS tables to force a rebuild, launch. Browsing works; search shows an indexing state rather than partial results. |
| 3.22 | Clearing the query | Returns to newest-first immediately, no perceptible delay. |

---

## 4. Performance, latency, and stutter — P1

This is the section that decides whether the rewrite was worth it. Run each
case at **three volumes**: 1000, 10000, and 50000 entries. Record the number
at each; a budget that holds at 1000 and breaks at 10000 is a failure.

### 4.1 Search typing latency — the headline case

**Steps.** Open the wall. Type `swift` one character at a time at a normal
pace (~100ms between keys). Then hold backspace to clear.

**Pass.** No visible stutter in the text field. Characters appear as typed —
the field must never lag behind the keyboard.

**Budget.**

| Volume | Results settle after typing stops |
| --- | --- |
| 1000 | < 150ms |
| 10000 | < 300ms |
| 50000 | < 600ms |

> Typing coalesces into one search after 150ms of settling, so a burst should
> produce exactly one query. Measured cost of a broad single-term query at
> 8000 entries is ~67ms. If the field itself lags, the debounce is not
> working and the module actor is being hit per keystroke.

**Also check.** Type a single very common character (`e`, or `的`). This is
the worst case: it matches nearly everything. It must still settle within
budget, not just narrow queries.

### 4.2 Copy while searching — actor contention

**Steps.** Start typing a broad query. While results are loading, copy
something in another app.

**Pass.** The copy is captured. Capture is not dropped or delayed beyond the
normal budget in section 2.

**Why.** Search and capture share the module actor. A long search blocking
capture is the specific regression this rewrite was meant to prevent.

### 4.3 Wall open latency

| Case | Budget |
| --- | --- |
| First open after launch (cold) | < 400ms to first painted row |
| Subsequent opens (warm) | < 150ms |
| Open at 50000 entries | Same as above — page size is fixed at 100, so volume must not matter |

**Pass.** The window appears already populated. A visible empty frame followed
by rows popping in is a failure.

### 4.4 Scrolling

**Steps.** Scroll the wall from top to bottom continuously through several
pages, including a stretch of image entries.

**Pass.** No dropped frames. Thumbnails may load progressively but must not
cause the scroll itself to hitch.

**Budget.** Zero hitches over 5s of continuous scrolling in Instruments →
Animation Hitches. Image thumbnails appear within 200ms of a row becoming
visible.

**Why it can fail.** Every thumbnail is individually AES-GCM encrypted on
disk; decryption on the main thread during scroll would be visible.

### 4.5 Large payloads

| Case | Pass |
| --- | --- |
| Copy a 50MB image | Captured. UI stays responsive during encryption. |
| Copy a 500MB image | Either captured without freezing, or rejected with a clear error. Never a beachball. |
| Copy a 5GB file (reference) | Instant — file references must not copy bytes. |
| Copy 500 files at once | Handled or cleanly rejected; no freeze. |

**Budget.** The menu bar item responds to a click within 200ms at all times,
including mid-capture.

### 4.6 Sustained copy load

**Steps.**

```bash
for i in $(seq 1 500); do printf 'load %d\n' "$i" | pbcopy; sleep 0.05; done
```

**Pass.** Every value captured. The wall stays usable throughout — open it
mid-run and scroll. CPU returns to idle within 5s of the loop ending.

**Budget.** AnyDoor's CPU stays under 30% of one core during the run.
Sustained 100% is a failure.

### 4.7 OCR and QR indexing under load

**Steps.** With Image Text Indexing on, copy ten screenshots in quick
succession, then immediately open the wall and search.

**Pass.** The UI never blocks on recognition. Search works while jobs are
pending. OCR text becomes searchable as each job finishes.

**Budget.** No UI stall over 100ms attributable to a Vision job. Verify with
`sample AnyDoor` during the run if anything feels off.

### 4.8 Retention cleanup

**Steps.** With 50000 entries, shorten retention from Unlimited to 7 days.

**Pass.** The affected count appears within 2s. After confirming, the wall
reflects the deletion promptly and stays responsive during reclamation.

**Budget.** Count computation < 2s. UI responsive throughout deletion.
Physical reclamation may lag (the contract allows 24h) but must not block.

### 4.9 Memory

| Checkpoint | Budget |
| --- | --- |
| Idle, wall closed, 10000 entries | < 150MB |
| Wall open, scrolled through 500 image rows | < 400MB peak |
| Settled 30s after closing the wall | Returns near idle — a monotonic climb across open/close cycles is a leak |

Repeat the open/scroll/close cycle ten times and confirm the settled figure
does not drift upward.

### 4.10 Disk growth

**Steps.** Record `du -sh` of the store root. Run a heavy session (200 mixed
copies including images). Record again.

**Pass.** Growth is proportional to what was actually stored. Settings →
Clipboard's reported usage matches `du` within a few percent. WAL does not
grow without bound across a long session.

### 4.11 Launch impact

**Steps.** With 50000 entries, quit and relaunch. Time from launch to the
menu bar item being clickable.

**Pass.** No regression versus a small history.

**Budget.** < 1.5s. Note that the store opens synchronously during
`AppDelegate.init`; an integrity check over a large trigram index is the
thing to watch here.

---

## 5. Retention, protection, deletion — P1

| # | Case | Pass |
| --- | --- | --- |
| 5.1 | Each preset | 1 day, 7 days, 30 days, 3 months, 6 months, 1 year, Unlimited all selectable and enforced. |
| 5.2 | Shorten with affected entries | Exact count shown, confirmation required, period and deletion commit together. |
| 5.3 | Shorten with zero affected | Applies immediately, no prompt. |
| 5.4 | Count changes during the prompt | Prompt refreshes rather than committing a stale count. |
| 5.5 | Favorite protection | A favorited entry older than the period survives indefinitely. |
| 5.6 | Tag protection | Same for a tagged entry. |
| 5.7 | Losing last protection | Unfavorite an old protected entry. It gets a fresh window, not immediate deletion. |
| 5.8 | Deleting a tag definition | Membership removed from entries; entries that lose their last protection get a fresh window. |
| 5.9 | Expired entries | Gone from the wall, from search, from counts, and from duplicate reuse — all at once. |
| 5.10 | Clear History, default scope | Confirms first. Protected entries survive. Tag definitions, settings, and the live pasteboard survive. |
| 5.11 | Clear History, including protected | The checkbox updates the count and removes everything. |
| 5.12 | Usage is not capture | Preview, copy, and paste an old entry. It does not move to the top and its retention does not extend. |
| 5.13 | Storage reclaimed | After a large deletion, physical usage drops within 24h without a longer period resurrecting anything. |

---

## 6. Encryption and privacy — P0

| # | Case | Steps | Pass |
| --- | --- | --- | --- |
| 6.1 | **No plaintext at rest** | Copy a unique string like `CANARY-8f3a2b`. Then `grep -r 'CANARY-8f3a2b' ~/Library/Application\ Support/dev.bybee.AnyDoor/` | No match anywhere, including WAL. |
| 6.2 | Payload files encrypted | Copy an image. `xxd` the newest file under `payloads/`. | Starts with the `ADCHPAYL` envelope magic, not PNG/JPEG magic. |
| 6.3 | No plaintext in temp | Repeat 6.1 against `/tmp`, `$TMPDIR`, and `~/Library/Caches`. | No match. |
| 6.4 | Nothing in logs | `log show --last 10m --predicate 'subsystem == "dev.bybee.AnyDoor"'` after copying the canary. | Clipboard content, paths, and search terms never appear. |
| 6.5 | Keychain locked | Lock the login keychain, copy something, unlock. | Capture pauses, then resumes from a new baseline. Nothing from the locked period is imported. |
| 6.6 | **Key missing** | Delete the Keychain item. Launch. | Store Unavailable with retry and an explicitly confirmed reset. The database is **not** replaced or wiped silently. |
| 6.7 | Reset action | Use the confirmed Reset Clipboard History. | History cleared, a new key created, the app works. |
| 6.8 | Backup excludes history | Settings → Sync, export a backup. Inspect it. | No clipboard entries, no keys, no exclusion-list secrets. |
| 6.9 | Sync excludes history | With sync configured, confirm the sync file. | Same. Clipboard history is device-local. |
| 6.10 | Cross-identity | Run `swift run AnyDoor` after using the installed app. | Documented behavior in `clipboard-history-keychain-integration.md` holds; no silent data loss. |

---

## 7. UI and interaction — P1

| # | Case | Pass |
| --- | --- | --- |
| 7.1 | Wall keyboard navigation | Arrows, Home/End, Return to paste, Esc to dismiss. |
| 7.2 | Facet filter | Each of Text, Link, Email, Color, Image, Screenshot, File, QR Code filters correctly and is single-select with All. |
| 7.3 | Source filter | ⌘K opens the source menu; counts match; a removed source clears the filter. |
| 7.4 | Tags | Create, rename, delete, assign, unassign. Category order persists across relaunch. |
| 7.5 | Favorites | Toggle from the wall and from the popover. |
| 7.6 | Text editing | Edit a single-item text entry. Id, source, capture time, favorite, and tags survive; recency does not move; search reflects the new text. |
| 7.7 | Zero-length edit | Rejected. Whitespace-only accepted. |
| 7.8 | Quick Look | Opens for image and file entries; closes cleanly. |
| 7.9 | Paste into various targets | Plain text, rich text, image, and file targets all receive the right representation. |
| 7.10 | Plugin context actions | Convert Image appears only while the Image Conversion plugin is installed and acts on the right entry. |
| 7.11 | Menu-bar popover | The compact history popover lists, filters, and pastes correctly. |
| 7.12 | Localization | Switch between 简体中文 and English. Every new string is translated; no raw keys. |
| 7.13 | Empty states | Fresh install, no search results, and filtered-to-empty each show a distinct sensible state. |
| 7.14 | Error surface | Trigger an operation failure (see 8.2). One rate-limited error, not a stream of alerts. |

---

## 8. Failure and recovery — P0

| # | Case | Steps | Pass |
| --- | --- | --- | --- |
| 8.1 | Corrupt database | Overwrite bytes in `history.sqlite`. Launch. | Store Unavailable with retry and confirmed reset. No silent recreation. |
| 8.2 | Disk full | Fill the volume (or use a small disk image), then copy. | The new entry is rejected. Existing history and the live pasteboard survive. One rate-limited error. |
| 8.3 | Corrupt single payload | Overwrite one file in `payloads/`. | Only that entry's payload action is disabled. Everything else works. |
| 8.4 | Kill mid-capture | Force-quit while copying a large image. Relaunch. | No committed reference to an unfinished file. At worst an encrypted orphan, counted in storage usage. |
| 8.5 | Read-only store directory | `chmod 500` the store root. Launch. | Clear failure, no crash, no data loss on restore. |
| 8.6 | Missing payload file | Delete a payload file referenced by an entry. | That entry degrades gracefully; the list still renders. |
| 8.7 | Clock moved backward | Set the system clock back a day, copy, restore. | No entries vanish; retention does not misfire. |

---

## 9. Adjacent-feature regression sweep — P1

The branch touched 164 files. Confirm it did not break its neighbours.

- [ ] Global hotkeys still fire; the event tap survives a search burst
- [ ] Hyper Key unaffected
- [ ] Command Palette opens, searches, and drills in
- [ ] Screenshot capture and annotation; auto-copy still lands in history once
- [ ] Screen recording
- [ ] Translation, including copy-from-result (must not create a history entry)
- [ ] Hosts plugin install/uninstall
- [ ] Image Conversion plugin, including its clipboard context action
- [ ] Script Plugins, including a plugin's `copy` capability
- [ ] Config sync export/import round trip
- [ ] Settings window: every tab opens, no focus loss on switch
- [ ] Scheduled Shutdown
- [ ] Sparkle update check

---

## Reporting

For any failure record: case number, volume (entry count), the measured value
against its budget, whether it reproduces, and a `sample AnyDoor` trace for
anything that stalls. A perf failure without a number is not actionable.
