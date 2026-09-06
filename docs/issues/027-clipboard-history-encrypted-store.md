---
id: 027
github: 80
title: "Clipboard History v2: encrypted store, schema, keys, and payload publication"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decisions: ADR-0011, ADR-0013, ADR-0014, ADR-0022, and ADR-0025.

## What to build

Implement the device-local Clipboard History Store behind
`ClipboardHistoryModule`. The store root is the pinned
`ClipboardHistory/` Application Support directory and contains one SQLCipher
database plus encrypted owned payloads. Define versioned relational storage for
entries, ordered items, representations, facets, file members, searchable field
rows, tag assignments, duplicate candidates, derived-job state, retention
state, and maintenance metadata. Concrete table and column names remain an
internal implementation choice.

Generate one device-only Keychain master key under fixed service and account
identifiers shared by development and installed process identities. Derive
independent SQLCipher and AES-GCM keys with versioned HKDF contexts. Configure a
GRDB `DatabasePool` with WAL, foreign keys, incremental auto-vacuum, and core
secure deletion. Missing keys, locked keys, authentication failures, and failed
integrity checks produce the typed module states defined by the PRD; none may
silently replace or reset the store.

Implement immutable AES-GCM payload files and the publish-before-reference
protocol. New encrypted files become durable before a database transaction can
reference them. Deletion removes the logical reference before asynchronous
reclamation. Reconciliation may delete unreferenced encrypted or staging files
after a grace period but never writes plaintext temporary files.

Provide explicit, confirmed reset as a module operation. It removes the
unreadable store and old key only after the host has supplied confirmation; it
is never an automatic recovery path.

## Acceptance criteria

- [ ] Real temporary SQLCipher stores exercise every schema migration and pass database, foreign-key, and cipher integrity checks
- [ ] The production Keychain adapter uses a fixed when-unlocked, this-device-only item and never creates a replacement key while an unreadable store exists
- [ ] A key created by the development process identity opens the installed app's pinned store, and the reverse path has explicit, tested ACL-prompt behavior
- [ ] SQLCipher and payload keys use independent versioned derivation contexts; thumbnails use the authenticated payload scheme
- [ ] Payload fault injection covers write, authentication, durability, transaction, deletion, and orphan-reconciliation boundaries
- [ ] A committed database row can never reference an unfinished payload; a crash may leave only an encrypted orphan
- [ ] The database and WAL remain encrypted under SQLCipher, and maintenance can checkpoint and truncate WAL
- [ ] Locked, missing-key, corrupt-database, corrupt-payload, and explicit-reset outcomes match the PRD without deleting unrelated history
- [ ] The target writes no clipboard content, paths, search values, or payload bytes to logs or persistent plaintext files

## Out of scope

Pasteboard classification, duplicate reuse, FTS tables, retention policy,
legacy extraction, and user interface wiring are separate tickets.

## Blocked by

Ticket 026.
