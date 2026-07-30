---
status: accepted
---

# Encapsulate Clipboard History as a deep module

The refactor introduces a `ClipboardHistory` Swift Package target whose concrete
`ClipboardHistoryModule` instance owns capture classification, canonicalization,
duplicate reuse, retention, encryption, payload publication, SQLite schema and
migrations, search indexing, OCR and QR job state, paging, and maintenance. The
target may depend on AppKit, Vision, CryptoKit, Security,
UniformTypeIdentifiers, GRDB, and SQLCipher, but not SwiftUI, Core panel types,
PluginInterface, or another AnyDoor feature module.

The module presents one small external interface:

- start or stop passive observation and report status;
- record an explicit AnyDoor-produced capture;
- fetch a page for a query and opaque cursor;
- apply a typed history mutation and return its outcome; and
- materialize one entry for normal paste, plain-text paste, preview, or a
  host-owned action.

Typed request and result values carry domain data, not database records, file
layout, SQL expressions, Keychain handles, or GRDB observations. Materialized
owned bitmaps are decrypted in-memory data; encrypted payload URLs never cross
the interface. App focus restoration, synthetic `Command-V`, SwiftUI view
state, localization, settings presentation, and Native Plugin routing remain
host responsibilities.

`AppDelegate` constructs one module instance and injects it into the clipboard
window controller, providers, and host adapters. The refactor does not preserve
a mutable global `ClipboardHistoryStore.shared`, add pass-through wrappers, or
expose separate public repository, search, encryption, and retention
interfaces. Those are internal implementation details and internal seams.

Tests cross the same external interface as production callers. They use real
temporary SQLCipher databases and files, named pasteboards, and an injected
clock. Vision recognition and Keychain key access have internal seams because
production and deterministic test adapters both exist. No external protocol is
introduced merely to mock GRDB, SQLite, or the filesystem.

Legacy SwiftData extraction is a host adapter because the old model shares the
application's store. It emits versioned legacy transfer values to the module's
staging migration path; it never teaches the new module about unrelated
AnyDoor models.

Keeping the existing cluster of `ClipboardHistoryStore`, `ClipboardSearch`,
`ClipboardCapture`, persistence-aware views, and independent payload helpers
was rejected. The new invariants span every one of them, so retaining shallow
interfaces would duplicate transaction ordering and make UI callers understand
storage internals. A protocol per subsystem was also rejected: one production
implementation plus mocks would add hypothetical seams rather than useful
variation.

Consequences:

- Clipboard views stop using SwiftData `@Query` and consume view state produced
  from module pages and status updates.
- The module's interface is the primary test surface; old tests that assert
  shallow helper internals are replaced when equivalent behavior is covered
  through the module.
- SQLCipher and GRDB dependencies stay localized to one target even though their
  linked product reaches the executable.
- The host can evolve UI and plugin presentation without learning database or
  encryption rules, while storage and search can evolve without editing every
  caller.
