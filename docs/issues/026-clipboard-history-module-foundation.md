---
id: 026
github: 79
title: "Clipboard History v2: establish the deep module and SQLCipher seam"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decisions: ADR-0013 and ADR-0025.

## What to build

Create the `ClipboardHistory` Swift Package target and the narrow concrete
`ClipboardHistoryModule` interface that every later ticket extends internally.
Add the exact `sqlcipher/GRDB.swift` 7.11.1 dependency, which resolves
`sqlcipher/SQLCipher.swift` 4.17.0, and add a dedicated
`ClipboardHistoryTests` target.

The external interface consists only of typed capture, monitoring, paged query,
mutation, materialization, and status operations. Public values describe
Clipboard History domain data; they never expose GRDB records, SQL, Keychain
handles, database paths, or encrypted payload URLs. The target may depend on
the frameworks listed in ADR-0025 but must not depend on SwiftUI, the `AnyDoor`
target, `PluginInterface`, or another feature module. It has no mutable global
module or store singleton.

Land one tracer bullet through the real dependency: with an injected test key,
the concrete module opens a temporary encrypted SQLCipher database, applies a
minimal versioned migration, and returns an empty first page through its public
query operation. Do not wire the module into `AppDelegate` yet.

Add the new dependency licenses to `THIRD-PARTY-LICENSES.md`. Preserve the
approval-spike evidence from ADR-0013 rather than adding a second temporary
spike project to the repository.

## Acceptance criteria

- [ ] `Package.swift` pins `sqlcipher/GRDB.swift` at 7.11.1 and the resolved lockfile pins `sqlcipher/SQLCipher.swift` at 4.17.0
- [ ] `ClipboardHistory` and `ClipboardHistoryTests` build in Swift 6 language mode on macOS 14+
- [ ] A real SQLCipher tracer test opens an encrypted database and fetches an empty page through `ClipboardHistoryModule`
- [ ] A wrong key cannot open the tracer database, its header is not plaintext SQLite, and the runtime reports SQLCipher 4.17.0 with FTS5 and trigram support
- [ ] The module's interface exposes no persistence, encryption, filesystem-layout, SwiftUI, or plugin types
- [ ] No mutable global Clipboard History singleton or pass-through repository protocols are introduced
- [ ] Link inspection shows the tracer executable using `SQLCipher.framework` without a direct `/usr/lib/libsqlite3` dependency
- [ ] Required SQLCipher and GRDB license texts are bundled

## Out of scope

The complete schema, Keychain lifecycle, payload storage, capture behavior,
search, migration, UI wiring, and removal of the existing SwiftData
implementation belong to later tickets.

## Blocked by

None. This is the first implementation ticket.
