# Hosts Editing Feature — Design

- Date: 2026-06-03
- Status: Approved (revised per review 2026-06-03)
- Component: AnyDoor menu bar app

## Overview

Add a hosts-file management feature to AnyDoor. Users can create, edit, and
delete named host profiles, activate any subset of them (multiple active at
once, merged), and apply the result to `/etc/hosts`. The system's pre-existing
hosts content is never modified by AnyDoor; it is shown read-only with an
"open in external editor" entry point. Writes to `/etc/hosts` go through a
privileged helper so the user authorizes once instead of on every change.

The UX reference is the Raycast `ihosts` extension, adapted to AnyDoor's
existing menu-bar-panel + hover-popover interaction model.

## Goals

- Create / edit / delete user-defined host profiles.
- Activate profiles via checkboxes; multiple active profiles are merged into
  one managed block.
- Never modify the system's existing hosts content. Show it read-only and
  provide an "open `/etc/hosts` in default editor" action.
- Password-free writes after a one-time approval (privileged helper).
- One-time backup of the original `/etc/hosts`, plus two restore actions:
  a safe "remove managed block" and a confirmed "restore first-run backup".

## Non-Goals (YAGNI for v1)

- The "All Hosts" dropdown filter from the reference screenshot.
- Importing hosts from a remote URL.
- Per-profile scheduling / automation.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Privilege model | Privileged helper via `SMAppService` (LaunchDaemon) | Project already ships Developer ID + hardened runtime + notarization (the only hard prerequisite). One-time approval, password-free thereafter, no security downgrade. AnyDoor is a long-lived resident app, so `chmod 777` is rejected. |
| Helper lifecycle | On-demand (no `RunAtLoad` / `KeepAlive`, `MachServices` only) | Zero resident process; launchd spawns it on XPC connect and it exits when idle. |
| UI surface | Popover for quick activation + separate window for editing | High-frequency activation stays lightweight (matches port-manager / window-layout pattern); low-frequency editing opens a dedicated window. |
| File composition | Marked managed block; all content outside the block (prefix AND suffix) untouched | AnyDoor only rewrites its own delimited block. Satisfies "system hosts is not editable in-app". Safest option. |
| Activation | Multiple profiles active, merged | Matches the reference screenshot (several checkmarks). |
| Persisted state semantics | Persisted state always equals "successfully applied to the system" | A failed write never leaves a divergent persisted state (see Write Flow). |

## Pre-Implementation Spikes (do these first)

These must be validated on a signed/notarized build before the dependent
implementation tasks start. They are the highest-risk unknowns.

1. **`SMAppService.daemon` registration + signing.** Confirm the exact, current
   requirements for registering a privileged LaunchDaemon with
   `SMAppService.daemon(plistName:)` on the supported macOS range: the
   LaunchDaemon plist keys, where it must live in the bundle, the helper's
   embedded `Info.plist` / entitlements, and how the client is authorized.
   Note: `SMAuthorizedClients` belongs to the legacy `SMJobBless` model and is
   NOT assumed here — the client-authorization mechanism for `SMAppService` must
   be verified against up-to-date docs (ctx7) and a working spike. Output: a
   minimal helper that registers, accepts one XPC call, and runs as root.
2. **Caller code-signature validation** (see Helper Security Boundary) — verify
   the public API path works end-to-end against the real signed app.

## Architecture

```
┌─ UI ───────────────────────────────────────────────────────┐
│  HostsManagerPopoverView      (menu-bar hover popover)        │
│  HostsEditorWindowController + HostsEditorView (editor window) │
└───────────────┬─────────────────────────────────────────────┘
                │ read/write profiles, trigger activation
┌─ Business ─────▼─────────────────────────────────────────────┐
│  HostsManager  (@MainActor @Observable, single source of truth)│
│    - bootstrap(modelContainer:)  // reuses AppDelegate's container│
│    - profile CRUD (SwiftData)                                  │
│    - read /etc/hosts, compose, invoke writer                   │
│  HostsFile     (pure logic: parse prefix/block/suffix, compose) │
│  HostsWriter   (protocol)                                      │
│    ├ PrivilegedHelperWriter  (XPC -> helper; production)       │
│    └ AppleScriptWriter       (dev / ad-hoc fallback)           │
│  HelperManager (SMAppService registration / status / guidance) │
│  HostsBackupStore (one-time original snapshot + restore)       │
└───────────────┬─────────────────────────────────────────────┘
                │ XPC (NSXPCConnection)
┌─ Privileged (root) ▼─────────────────────────────────────────┐
│  AnyDoorHostsHelper  (LaunchDaemon, on-demand)                 │
│    - NSXPCListener; validates caller code signature            │
│    - serial write queue                                        │
│    - atomic write to /etc/hosts (temp in /etc -> rename, 644)  │
└───────────────────────────────────────────────────────────────┘
```

## Files

### New

- `Models/HostProfile.swift` — SwiftData model.
- `Services/Hosts/HostsManager.swift` — business single source of truth.
- `Services/Hosts/HostsFile.swift` — pure parse/compose logic (unit-testable).
- `Services/Hosts/HostsWriter.swift` — protocol + `PrivilegedHelperWriter` + `AppleScriptWriter`.
- `Services/Hosts/HelperManager.swift` — `SMAppService` lifecycle.
- `Services/Hosts/HostsBackupStore.swift` — original snapshot + restore.
- `Sources/HostsHelperShared/HostsHelperProtocol.swift` — XPC protocol + shared constants (mach service name, markers); SPM library target depended on by both the app and the helper.
- `Sources/AnyDoorHostsHelper/main.swift` — helper executable (`NSXPCListener`); SPM executable target.
- `Resources/dev.bybee.AnyDoor.HostsHelper.plist` — LaunchDaemon plist (placed into the bundle at build time).
- `Views/Hosts/HostsManagerPopoverView.swift`
- `Views/Hosts/HostsEditorWindowController.swift`
- `Views/Hosts/HostsEditorView.swift`

### Changed

- `Models/BuiltinItem.swift` — add `case hostsManager` (kind `.submenu`) + `titleKey` / `symbol` / `defaultOrder` / `defaultVisibility`.
- `Utilities/L10n.swift` — add the `hostsManager` title key (and any UI keys).
- `Resources/Localizable.xcstrings` — add zh-Hans + en translations (enforced by `LocalizationCoverageTests`).
- `Views/MenuBarView.swift` — add `.submenu(.hostsManager)` popover branch.
- `AppDelegate.swift` — register `HostProfile` in the ModelContainer schema; call `HostsManager.shared.bootstrap(modelContainer:)`.
- `Package.swift` — add the helper executable target + shared protocol library target.
- `scripts/release.sh` / `Makefile` — build (universal), place, and sign the helper.

## Data Model

```swift
@Model final class HostProfile {
    @Attribute(.unique) var id: UUID
    var name: String                 // e.g. "Dev Host"
    var content: String              // raw hosts text block for this profile
    var isActive: Bool = false       // included in the managed block when true
    var displayOrder: Double = 0     // Float ordering, lower = earlier
    var createdAt: Date
    var updatedAt: Date              // drives the date shown in the list

    init(name: String, content: String = "", isActive: Bool = false, displayOrder: Double = 0) {
        self.id = UUID()
        self.name = name
        self.content = content
        self.isActive = isActive
        self.displayOrder = displayOrder
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
```

- "System Hosts" is not a database record; it is the content of `/etc/hosts`
  outside the managed block (prefix + suffix), read at runtime, shown read-only.
- Follows project conventions: `@Attribute(.unique) id`, `displayOrder: Double`,
  inline defaults for lightweight migration, `createdAt` set in `init`.
- `HostsManager` is a `@MainActor @Observable` singleton bootstrapped with the
  app's single `ModelContainer` (never creates its own), mirroring `PanelStore`.

## HostsFile — Parse and Compose (pure logic)

Markers (shared constants in `HostsHelperShared`):

```swift
let begin = "# >>> AnyDoor managed block — do not edit below this line >>>"
let end   = "# <<< AnyDoor managed block end <<<"
```

Parse into three parts so that content BOTH before and after the block is
preserved:

```swift
struct ParsedHosts {
    var prefix: String      // everything before `begin` (system content)
    var managed: String?    // content strictly between begin/end, if present
    var suffix: String      // everything after `end` (also system content)
}

func parse(_ raw: String) -> ParsedHosts
func compose(parsed: ParsedHosts, activeProfiles: [(name: String, content: String)]) -> String
```

- `parse`: when no markers are present, the whole file is `prefix`, `managed`
  is nil, `suffix` is empty. Malformed cases (begin without end, duplicate
  markers) resolve to a single well-defined interpretation (first `begin` /
  first matching `end`); leftover marker lines outside that pair are treated as
  ordinary system content.
- `compose`: emits `prefix` + managed block (active profiles concatenated in
  `displayOrder`, each prefixed with `# --- <name> ---`) + `suffix`. When there
  are no active profiles, NO managed block is emitted (block removed), but
  `prefix` and `suffix` are preserved.
- Idempotent: composing the output again yields identical output.
- Safe: every write re-parses the live file, so AnyDoor only ever rewrites its
  own block and preserves all system content before and after it, regardless of
  external edits.
- Marker-injection guard: a profile `content` line that matches the begin/end
  markers is stripped/escaped during `compose` so the block structure cannot be
  forged or broken.

## End-to-End Write Flow

The persisted state always equals what was successfully applied to the system.

- **Editing a non-active profile** (name/content): persist immediately via
  `save()`; no system write.
- **Toggling `isActive`, or editing an already-active profile**: apply first,
  persist only on success.

```
HostsManager.applyAndPersist(change):
    apply the change to an in-memory copy (do NOT save() yet)
    HostsBackupStore.ensureOriginalBackup()   // one-time, before first managed write
    raw    = read("/etc/hosts")                // plain read, no privilege
    parsed = HostsFile.parse(raw)
    active = profiles(with change applied).filter(\.isActive).sorted(by: displayOrder)
    newTxt = HostsFile.compose(parsed, active)
    do {
        try await writer.write(newTxt)         // the only privileged step
        modelContext.save()                    // persist only after success
        refresh read-only systemHosts view
    } catch {
        // roll back in-memory change; nothing persisted; surface error to UI
    }
```

Concurrency: activation toggles are debounced and serialized in `HostsManager`
so rapid clicks coalesce into a single, consistent write.

## XPC Protocol and Helper

Shared target `HostsHelperShared`, used by both the app and the helper:

```swift
@objc protocol HostsHelperProtocol {
    // returns nil on success, or an error message
    func writeHosts(_ content: String, withReply reply: @escaping (String?) -> Void)
    func helperVersion(withReply reply: @escaping (String) -> Void)
}
```

### Helper Security Boundary (`AnyDoorHostsHelper`, runs as root)

- `NSXPCListener(machServiceName:)`.
- **Caller validation** in `listener(_:shouldAcceptNewConnection:)`:
  - Read `newConnection.auditToken`.
  - `SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: auditTokenData], [], &code)`.
  - `SecCodeCheckValidity(code, [], requirement)` where the requirement string is
    `anchor apple generic and certificate leaf[subject.OU] = "<TEAM_ID>" and identifier "dev.bybee.AnyDoor"`.
  - On failure: do NOT set `exportedObject`; `invalidate()` the connection.
- **Request size cap**: reject `content` larger than a fixed limit (e.g. 1 MiB)
  to bound memory / prevent abuse.
- **Serialization**: all writes run on a single serial queue so concurrent XPC
  calls cannot interleave file operations.
- **Atomic write**: create a temp file in `/etc` (same filesystem as the target,
  so `rename` is atomic) via an `mkstemp`-style unpredictable name; write →
  `fsync` → `fchown root:wheel` → `fchmod 0644` → `rename()` over `/etc/hosts`.
- **On-demand lifecycle**: plist has no `RunAtLoad` / `KeepAlive`, only
  `MachServices`; launchd spawns the helper on connect and it exits when idle
  (zero resident footprint).

## SMAppService Registration

`HelperManager` wraps `SMAppService.daemon(plistName: "dev.bybee.AnyDoor.HostsHelper.plist")`
and handles the full status space, not just register-or-approve:

- `.enabled` — ready; proceed.
- `.notRegistered` — call `register()`.
- `.requiresApproval` — guide the user to System Settings → Login Items & Extensions.
- `.notFound` — surface an error (bundle/plist mismatch); fall back in dev.
- default/unknown — surface an error.

The LaunchDaemon plist is installed at `Contents/Library/LaunchDaemons/`. Exact
plist keys, helper embedded `Info.plist`, and client-authorization specifics are
finalized by Spike #1 before this task is implemented (do not rely on
`SMAuthorizedClients` without verification).

## Dev / Ad-hoc Fallback

`swift run` and `make install` use ad-hoc signing, where `register()` fails.
Handle it transparently:

```swift
// HostsManager bootstrap
if helperManager.ensureRegistered() {       // status resolves to .enabled
    writer = PrivilegedHelperWriter()        // signed/notarized production build
} else {
    writer = AppleScriptWriter()             // dev / ad-hoc: prompt each write
}
```

`AppleScriptWriter` does NOT chmod the target. It writes to an unpredictable
temp path (not a predictable `/tmp/xxx`), then runs, with correct shell
quoting of every path:

```
do shell script "/bin/cp <quoted-temp> /etc/hosts && /bin/rm -f <quoted-temp>" with administrator privileges
```

The business layer only knows the `HostsWriter` protocol, so it is agnostic to
the implementation.

## Backup / Restore

- `HostsBackupStore.ensureOriginalBackup()` — before AnyDoor's first managed
  write, snapshot the current `/etc/hosts` verbatim into App Support
  (`~/Library/Application Support/dev.bybee.AnyDoor/hosts-backup/original.hosts`).
  Runs exactly once (guarded by file existence).
- **Restore is two distinct actions** (the destructive one must not be the
  default):
  - `removeManagedBlock()` — DEFAULT, safe: re-parse the live file and
    `compose` with no active profiles, so only AnyDoor's block is removed and
    all current system content (prefix + suffix) is preserved. Does not depend
    on the backup.
  - `restoreFirstRunBackup()` — confirmation-gated, destructive: overwrite
    `/etc/hosts` with the first-run snapshot. The UI warns that any external
    changes made after the first run will be lost.

Both go through the `HostsWriter`.

## UI

### Popover (quick activation) — `HostsManagerPopoverView`

Follows the `PortManagerPopoverView` pattern.

```
┌─────────────────────────────┐
│ 🔧 System Hosts        [Open] │  read-only; [Open] opens /etc/hosts externally
├─────────────────────────────┤
│ ✅ Dev Host          2023    │  checkbox = active; clicking the row toggles
│ ⭕️ social            Mar 6   │
│ ✅ muse-dam          Mar 5   │
├─────────────────────────────┤
│ + New             ✎ Edit All │  opens the editor window
└─────────────────────────────┘
```

- Toggle → `HostsManager.setActive(_:_:)` → `applyAndPersist`.
- System Hosts row is not checkable; it offers only the "open file" action.
- A status bar appears when the helper is not enabled, with an "authorize"
  button that deep-links to System Settings.

### Editor window — `HostsEditorWindowController` + `HostsEditorView`

Follows the `CommandPaletteWindowController` pattern (singleton + `NSPanel` +
`NSHostingView` + `.accessory` activation). Master-detail layout:

- Left: profile list — add / delete / drag-reorder (`onMove` → `displayOrder`) /
  activate checkbox / search; System Hosts pinned at top.
- Right: selected user profile → `name` field + monospaced `TextEditor` for
  `content`; selected System Hosts → read-only display + "open file" button,
  editor disabled.
- Save: debounce edits then persist per the Write Flow rules above.
- Includes the two restore actions and the helper-authorization status.

## Panel Integration

- `BuiltinItem` adds `case hostsManager`: `kind = .submenu`, `titleKey`,
  `symbol` (suggest `list.bullet.rectangle` or `network`), `defaultOrder`,
  `defaultVisibility`.
- `Utilities/L10n.swift` + `Resources/Localizable.xcstrings` must gain the new
  key and zh-Hans/en translations — `BuiltinItemLocalizationTests` and
  `LocalizationCoverageTests` fail otherwise.
- `BuiltinPreferenceSeeder` already appends new cases (`maxOrder + 100`); no
  special backfill needed.
- `MenuBarView` adds a `HoverPopoverTarget.submenu(.hostsManager)` branch that
  mounts `HostsManagerPopoverView` and runs `Task { await HostsManager.shared.refresh() }`.
  Structurally identical to the port-manager integration.

## Error Handling and Edge Cases

- Helper not enabled / registration failed: status bar + "authorize" button
  (deep-link to System Settings); checked before any write.
- Write failure / user cancels authorization: surface a clear message and roll
  back the in-memory change; nothing is persisted (see Write Flow).
- External edits to the system section (prefix or suffix): re-parse before each
  write; both are preserved by construction.
- Profile content containing the marker text: stripped/escaped in `compose`.
- Empty / duplicate names, deleting an active profile: validated in the editor;
  after deletion re-run the write flow.

## Build / Signing Changes (`release.sh`, depth-first before the app)

Reuse the existing universal build flags; build and sign the helper with the
same architectures, depth-first (before signing the app):

```bash
BUILD_FLAGS=(--build-system swiftbuild --arch arm64 --arch x86_64)
swift build -c release "${BUILD_FLAGS[@]}" --product AnyDoorHostsHelper
HELPER_BIN="$(swift build --show-bin-path -c release "${BUILD_FLAGS[@]}")/AnyDoorHostsHelper"
cp "$HELPER_BIN" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp Resources/dev.bybee.AnyDoor.HostsHelper.plist "$APP/Contents/Library/LaunchDaemons/"
# sign helper before the app (hardened runtime + timestamp); notarization covers it
codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/AnyDoorHostsHelper"
```

## Testing Strategy

- `HostsFile` pure-logic unit tests (primary):
  - extract / compose / idempotency,
  - no-marker file,
  - **suffix preservation** (content after the block survives a rewrite),
  - duplicate / missing markers (begin without end, etc.),
  - **marker injection** (profile content containing the markers),
  - **managed block removed** when no active profiles,
  - external edits to prefix and suffix preserved.
- `HostsManager`: inject a mock `HostsWriter` + in-memory `ModelContainer`:
  - composed write content is correct,
  - **write failure rolls back and persists nothing**,
  - **concurrent toggle / debounce** coalesces into one consistent write,
  - non-active edits persist without a system write.
- `HostsBackupStore`: one-time snapshot; `removeManagedBlock` vs
  `restoreFirstRunBackup` produce the expected content.
- L10n: existing `BuiltinItemLocalizationTests` / `LocalizationCoverageTests`
  must pass with the new `hostsManager` key.
- Helper signature validation / end-to-end: requires a signed build; manual,
  covered by the spikes.
```
