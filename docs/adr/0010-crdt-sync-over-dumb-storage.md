# Config sync is client-side CRDT merge over dumb file storage

Multi-device config sync is implemented entirely client-side. Each machine
maintains a Sync Document — a record-level last-writer-wins map over the
portable configuration (one hybrid logical clock per record, device id as
tiebreak, deletions kept as tombstones) — writes it to its own Device State
File, and merges every peer state file it can read. The storage layer never
interprets data; anything that can hold files works. The v1 transport is a
user-chosen Sync Folder (typically inside a cloud drive's local mount, so
Google Drive / Dropbox / iCloud Drive / NAS are all covered by their own
desktop clients); WebDAV is the planned second transport for the
self-hosted/account crowd. Sync is optional and off by default.

We chose this over the alternatives:

- **A hosted account-based sync service (the Raycast model)** buys sub-second
  push and storage independence at the cost of a permanent second product —
  auth, hosting, abuse handling, server/client version skew, ops forever —
  untenable for a free indie app. Because state-based merge needs nothing
  from the server, a hosted option, if ever warranted, is just an
  authenticated blob store behind the same transport seam; the client
  architecture would not change.
- **Per-provider OAuth APIs (Google Drive / Dropbox REST)** cost one
  integration, one app registration, and one review pipeline per provider
  (Google's being notoriously heavy — remotely-save paywalls exactly that
  backend), and still leave NAS/WebDAV users out.
- **A single shared file (the Alfred model)** makes every machine a writer of
  the same blob; cloud clients then manufacture "conflicted copy" files the
  app cannot resolve — Alfred documents this failure mode and tells users to
  restore from a backup. One-writer-per-file removes the conflict at the
  source instead of handling it.
- **Backup + restore semantics** (the previous iteration of this design) was
  rejected by the owner: it never converges without manual restore actions,
  and an eagerly-updated backup is a mirror that follows the user into their
  mistakes.

Record-level LWW is deliberate: config records are small and independently
keyed (bundle id / item key / UUID / defaults key). Field-level merge and
interactive conflict UI were judged over-engineering; a concurrent edit to
the same record resolves deterministically to the newer clock and the loser
is dropped silently.

Consequences:

- Convergence latency is whatever the folder's syncer delivers (seconds to
  minutes). Accepted; there is no push channel.
- Machine-local settings (helper approval, the Sync Folder choice itself,
  Script Plugin state, …) must never enter the Sync Document or machines
  would fight over them. The existing `SyncSettingsRegistry` whitelist is
  the enforcement point.
- Deletions must flow through tombstones (retained ~90 days before GC), so
  stores must report deletions to the sync engine, not just upserts.
- The merge must stay commutative, associative, and idempotent — property
  tests pin this; no cursor or "last synced" state may be load-bearing.
- Peer files under File Provider may be dataless: a read can block or fail.
  Reads are async with timeouts, and a failed read only delays convergence,
  never corrupts state.
- Manual export/import stays, reframed as Config Backup for one-shot
  migration; it shares DTOs with sync but not semantics.
