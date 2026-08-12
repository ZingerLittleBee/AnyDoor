---
status: accepted
---

# Store Clipboard History in a dedicated SQLite database

Clipboard History will use one dedicated SQLite database for entry metadata,
retention state, duplicate fingerprints, OCR state, and search data. Owned
payloads live in a sibling directory. Together they form the device-local
Clipboard History Store and are the only files included in History Storage
Usage. File Reference Entries retain paths in the database but keep the
referenced files themselves outside this boundary.

GRDB is the Swift access layer over SQLCipher's SQLite engine. It provides
migrations, transaction APIs, serialized writes, database observation, and
FTS5 integration. ADR-0014 requires whole-database encryption, so AnyDoor
bundles SQLCipher rather than linking Clipboard History to the operating
system's unencrypted SQLite engine.

The store uses a GRDB `DatabasePool` in WAL mode for concurrent paged reads and
one serialized write path inside the Clipboard History Module implementation.
Foreign keys are mandatory. The database is created with
`auto_vacuum=INCREMENTAL` and `secure_delete=ON`; maintenance checkpoints and
truncates the encrypted WAL, runs incremental vacuum, and reclaims unreferenced
payloads after logical deletion. This is how Expired Entries disappear
immediately while allocated History Storage Usage is physically reclaimed
within 24 hours.

The Clipboard History database is the sole structured source of truth. Record
creation, duplicate reuse, retention deletion, and search-index changes must be
transactional rather than split between independent persistence systems.
Clipboard History therefore leaves the shared SwiftData schema entirely; this
decision does not add another SwiftData `ModelContainer`.

A separate SwiftData configuration was rejected even though SwiftData can
assign model groups to separate stores. AnyDoor supports macOS 14, where
SwiftData does not provide the indexed full-text search and relevance ranking
required by Unlimited Retention. Keeping SwiftData records alongside a separate
search database would introduce dual-write consistency failures. Flat JSON or
payload-only storage was rejected because it cannot provide transactional
deduplication, indexed search, and cursor pagination efficiently.

Calling the system `SQLite3` C API directly was rejected. Its marginally smaller
wrapper footprint does not justify owning statement lifetimes, parameter
binding, migrations, observation, error mapping, and Swift concurrency
isolation throughout the feature, and it does not satisfy the whole-database
encryption requirement.

The pinned dependencies are `sqlcipher/GRDB.swift` v7.11.1 over
`sqlcipher/SQLCipher.swift` 4.17.0 — the SQLCipher project's managed GRDB fork
and its lockstep SwiftPM package. The 4.17.0 prebuilt XCFramework was verified
on 2026-07-30 to contain arm64 and x86_64 macOS slices, SQLite 3.53.3,
`ENABLE_FTS5`, and the trigram tokenizer, and to create, open, and reopen an
encrypted database.

The approval spike completed on 2026-07-30 with Xcode 26.6 and Apple Swift
6.3.3, using Swift 6 language mode. SwiftPM resolved `sqlcipher/GRDB.swift`
7.11.1 and `sqlcipher/SQLCipher.swift` 4.17.0, built and ran an arm64
executable, created and reopened an encrypted database, rejected an incorrect
key, and left a non-plaintext database header. Through GRDB it also exercised
external-content trigram MATCH over CJK text, contentless-delete short-gram
MATCH and DELETE, and FTS5 `secure-delete` configuration on both tables.
`otool -L` showed a direct dependency on `SQLCipher.framework` and no direct
dependency on `/usr/lib/libsqlite3`; the executable's unresolved `sqlite3_*`
imports were provided by SQLCipher. The packaged macOS framework contains both
arm64 and x86_64 slices. The spike did not execute an x86_64 AnyDoor build, so
the universal release build and final executable-link inspection remain
acceptance gates rather than inferred spike results.

The source-built `skiptools/swift-sqlcipher` 1.11.0 is the fallback candidate
if the prebuilt binary becomes unmaintained. It is not a drop-in replacement:
adopting it requires a separate integration decision that may customize GRDB's
package wiring to the low-level `SQLCipher` product or replace the access
layer. The DuckDuckGo GRDB fork was rejected as stale (no release since March
2025).

Consequences:

- Clipboard views consume pages and status produced by the concrete
  `ClipboardHistoryModule` instead of using `@Query`.
- The shared application `ModelContainer` no longer registers
  `ClipboardHistoryItem`.
- Database, write-ahead-log, shared-memory, and payload files all contribute to
  History Storage Usage.
- Existing SwiftData records and payloads require a one-time migration.
- The dependency pins above are fixed before implementation begins, not during
  it. The Clipboard History target does not directly link the system SQLite
  library, and GRDB's `sqlite3_*` imports must bind to SQLCipher. Other AnyDoor
  frameworks may continue using their own system persistence implementation.
- The application bundle includes SQLCipher; its measured release-size cost is
  accepted in exchange for encrypted history and search data.
- ADR-0021 defines the concrete FTS5 trigram and short-gram search indexes.
- ADR-0022 defines the crash-consistent relationship between database rows and
  encrypted payload files.
- ADR-0025 localizes GRDB, SQLCipher, schema, search, and maintenance behind the
  Clipboard History Module's concrete interface.
- The store remains device-local and outside Config Sync and Config Backup.
- This scope does not add a standalone Clipboard History export or import.
