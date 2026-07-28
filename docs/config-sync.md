# Config Sync

AnyDoor can keep its configuration in sync across your Macs through a shared
folder — no account, no server, no per-provider integration. Pick a folder
inside anything that syncs files (Google Drive, Dropbox, iCloud Drive, a NAS,
Syncthing…), point every Mac at it, and app shortcuts, built-in preferences,
Quicklinks, and portable settings converge automatically.

Sync is **off by default** and fully optional. The manual export/import flow
(Settings → General → Backup & Restore) is unrelated: it produces a one-shot
snapshot file for migration or sharing, and stays available whether or not
sync is enabled.

## Setup

1. On your first Mac: **Settings → General → Sync**, turn on *Sync
   automatically*, and choose a folder inside your cloud drive's local mount
   (e.g. a `AnyDoor` folder in `~/Library/CloudStorage/GoogleDrive-…` or
   `~/Dropbox`).
2. On every other Mac: choose the **same** folder.
3. Done. Changes propagate within seconds to minutes, depending on how fast
   your cloud client moves the files.

Cloud-drive tip: mark the folder "available offline" / "keep downloaded" in
your cloud client. macOS File Provider can evict file contents ("dataless"
files); AnyDoor defends with timeouts and retries, but a locally-materialized
folder syncs noticeably faster.

## What syncs

- App shortcuts (hotkey → app bindings; app paths are re-resolved per machine
  from bundle IDs)
- Built-in item preferences (visibility, order, hotkeys)
- Quicklinks (including keywords and hotkeys)
- The whitelisted portable settings (`SyncSettingsRegistry`): menu bar icon,
  command palette hotkey, language, Hyper Key config, clipboard/capture/
  translation settings, the installed Native Plugin set, and more

## What never syncs

- Clipboard history, translation history, API keys (Keychain)
- Machine-local state: privileged-helper approval, Script Plugins and their
  developer mode, window positions
- The sync configuration itself (folder choice, device identity)

## How it works

Each Mac writes exactly **one** state file into the sync folder and reads
everyone else's:

```
<sync folder>/
├── AnyDoor-SyncState-<device-A-id>.json   ← Mac A writes only this
└── AnyDoor-SyncState-<device-B-id>.json   ← Mac B writes only this
```

A state file is the machine's *Sync Document*: one entry per configuration
record, each carrying a hybrid logical clock (wall time + logical counter +
device id). On every sync tick — launch, ~10 s after a config change, a
folder-change event, every 15 minutes, and on wake — the engine:

1. captures local changes into its document (new clock stamps; records that
   vanished locally become tombstones),
2. reads all peer files and merges them: per record, the newer clock wins,
3. applies the merged result to the local stores (including deletions), and
4. writes its own file back if anything changed.

The merge is commutative, associative, and idempotent (pinned by property
tests), so machines converge regardless of ordering, offline gaps, or how
often files arrive. Because every file has a single writer, cloud clients
never have to reconcile concurrent writes — the "conflicted copy" failure
mode of shared-preferences syncing (see Alfred's docs) structurally cannot
happen. Anything else in the folder, including conflict artifacts a cloud
client might still produce, fails the strict filename pattern and is ignored.

Conflict semantics:

| Scenario | Result |
| --- | --- |
| Two Macs edit different records | Both changes survive |
| Two Macs edit the same record | Newer clock wins everywhere, deterministically |
| One Mac deletes, another still has it | The deletion wins via tombstone (retained ~90 days) |

Deleting a record writes a tombstone rather than erasing the entry, so a Mac
that was offline for weeks cannot resurrect it. A concurrent same-record edit
resolves silently — there is no conflict UI, by design (ADR-0010).

## Failure modes

The Settings status line reports the last tick: *Last synced* on success, or
a reason on failure (folder missing / unreachable / not writable / apply
failed). A failed tick only delays convergence — it never corrupts state; the
next trigger retries. Unreadable or corrupt peer files are skipped
per-file. Detailed logs: Console.app, subsystem `dev.bybee.AnyDoor`,
category `sync`.

Disabling sync stops the engine but keeps your local configuration, the
machine's state file in the folder, and its local document — re-enabling
resumes where it left off.

## Design records

- [ADR-0010 — Config sync is client-side CRDT merge over dumb file
  storage](adr/0010-crdt-sync-over-dumb-storage.md): why folder-based
  transport beat a hosted service, per-provider OAuth APIs, and a single
  shared file; why record-level last-writer-wins is enough.
- [`CONTEXT.md`](../CONTEXT.md) — canonical vocabulary under *Config Sync &
  Backup* (Sync Folder, Device State File, Sync Document, Tombstone, …).
- Planned second transport: WebDAV (self-hosted Nextcloud / NAS / 坚果云),
  behind the same engine.
