# Port Management — Design

**Date**: 2026-05-21
**Status**: Revised after review (design phase)
**Author**: Brainstorming session

## Summary

Add a "port management" entry to the AnyDoor menu bar panel that, on hover, surfaces a popover listing all TCP listening ports on the machine. Users can search by port / process name / pid, switch between a list view (sorted by port) and a tree view (grouped by process), and kill processes inline. The feature reuses the existing hover-popover infrastructure (`HoverPopover` + `HoverGate`) used by the "App Shortcuts" entry.

## Goals

- Show all TCP listening ports with port number, process name, pid, bind address(es).
- Provide search across port / process name / pid with priority ordering.
- Provide list and tree views; remember the chosen view across sessions.
- Provide one-click kill (SIGTERM → 500ms → SIGKILL fallback) with inline failure feedback when the kernel rejects the signal (typically root-owned processes).
- Reuse `BuiltinItem` infrastructure so the entry can be reordered and hidden from the panel settings (same as the App Shortcuts entry).

## Non-Goals

- No UDP, established TCP, or per-connection inspection.
- No privilege escalation (no `sudo`, no `osascript with administrator privileges`, no privileged helper). System processes that the kernel refuses to signal stay visible with a permission-denied indicator.
- No continuous background scanning; data refreshes when the popover opens or on user request.
- No persistence of search text or tree expansion state across sessions.
- No keyboard navigation inside the list (up/down arrows, enter-to-kill).
- **No global hotkey for opening the port-manager popover in this iteration.** The existing menu-bar architecture only resolves submenu popovers when the menu bar panel is already open (it tracks a single trigger frame for the App Shortcuts row). Wiring a hotkey to open the menu bar, then mount the popover, then focus the search field is a separate piece of work that is explicitly deferred to a follow-up. Per-row hotkeys for `.submenu` items remain skipped in `PanelStore.rebuildHotkeySnapshots` as they are today.

## Clarifications Captured

| Topic | Decision |
|-------|----------|
| Port scope | TCP listening only (`lsof -nP -iTCP -sTCP:LISTEN`) |
| IPv4/IPv6 dual-stack | One row per `(pid, port)`; both bind addresses retained as a `binds: [PortBind]` array on the record |
| Kill mechanism | Darwin `kill(2)` direct syscall, SIGTERM → 500ms wait → SIGKILL fallback |
| Kill failure handling | Inline red icon + tooltip, auto-dismiss after 3s; no escalation prompt |
| Refresh strategy | Scan on popover open + manual ⌘R + auto-refresh after kill |
| Menu integration | New `BuiltinItem.portManager` with `kind = .submenu` |
| Hotkey support | **Deferred.** Existing infrastructure already filters out submenu hotkeys; no change in this iteration. |
| Persistence | Only the list/tree toggle (`UserDefaults`); search text and tree expansion are session-only |
| Tree default state | All groups collapsed by default |
| Kill icon on tree leaf rows | Not shown; killing the process row kills the pid (and consequently all its ports) |
| Scanning state UI | Centered `ProgressView` with label, no skeleton |
| Scan failure UI | Inline banner above the list, keeps last results visible, has a retry button |
| Subprocess runtime | Dedicated `SubprocessRunner` in `PortScanner` that drains stdout/stderr concurrently with `process.run()` (the existing `ShellRunner` reads the pipe only after `waitUntilExit()` and would deadlock on lsof's volume). |
| lsof empty result | Exit code 1 with empty stdout/stderr is treated as `[]`, not as failure. |

## Architecture

Three new units, each isolated and individually testable:

```
┌─────────────────────────────────────────────────────────────┐
│  MenuBarView → PanelRowView (.portManager row)              │
│    └─ HoverGate → HoverPopover → PortManagerPopoverView     │
│                                       ▲                     │
│                                       │ reads               │
│                                       ▼                     │
│  @MainActor @Observable PortInventory.shared                │
│    ├─ state: records / viewMode / searchText / isRefreshing │
│    │         killingPIDs / failedKillPIDs / lastError       │
│    └─ uses ───────────────────────────────────────────────┐ │
│                                                           │ │
│  actor PortScanner (conforms to PortScanning protocol)    │ │
│    ├─ scanTCPListening() async throws -> [PortRecord]     │ │
│    └─ kill(pid:signal:) -> SignalResult (nonisolated)     │ │
└───────────────────────────────────────────────────────────┴─┘
```

- `PanelStore` does **not** own port data. It only carries the `BuiltinItem.portManager` entry through its existing pipeline.
- `PortInventory` is the single source of UI truth for port-related state. Single-instance, MainActor-isolated, Observable.
- `PortScanner` is a stateless actor wrapping `lsof` parsing, optional `sysctl(KERN_PROCARGS2)` enrichment, and the `kill(2)` syscall. Its surface is captured by the `PortScanning` protocol for test injection.

## Components

### 1. `BuiltinItem.portManager`

New case in `Sources/AnyDoor/Models/BuiltinItem.swift`:

- `kind = .submenu`
- `title = "端口管理"`
- `symbol = "network"`
- Appended to `BuiltinItem.allCases` default ordering (tail).

`BuiltinPreferenceSeeder` automatically creates the SwiftData preference row on first launch (existing logic). No SwiftData schema changes.

### 2. Hotkey action (deferred)

No changes to `HotkeyAction`, `PanelStore.rebuildHotkeySnapshots`, or `HotkeyService` in this iteration. `PanelStore` already skips snapshot generation for items whose `kind == .submenu` (see `PanelStore.swift:202`), and the menu bar only resolves the popover anchor for the App Shortcuts row (`MenuBarView.swift:62`). Designing a "global hotkey opens menu bar then mounts a submenu popover" flow requires its own design pass and is intentionally out of scope.

**Settings UI must also hide the hotkey recorder for every submenu, not just App Shortcuts.** `PanelSettingsView.swift:92` currently special-cases `.builtin(.appShortcuts)`:

```swift
if case .builtin(.appShortcuts) = entry.source {
    Color.clear.frame(width: 130)   // reserve column width
}
```

Generalise this to all submenu-kind items so `.portManager` (and any future submenu) does not render a recorder the user can fill in but the system silently ignores:

```swift
if case let .builtin(item) = entry.source, item.kind == .submenu {
    Color.clear.frame(width: 130)
}
```

This is a one-line change and ships in the same iteration.

### 3. `PortScanner` (actor)

Files:
- `Sources/AnyDoor/Models/PortRecord.swift` — shared domain types.
- `Sources/AnyDoor/Services/PortScanner.swift` — actor + subprocess runner + parser.

#### Domain types (in `Models/PortRecord.swift`)

```swift
struct PortRecord: Sendable, Hashable, Identifiable {
    let port: UInt16
    let pid: pid_t
    let processName: String
    let executablePath: String?
    let commandLine: String?
    let binds: [PortBind]        // never empty; ordered ipv4 first then ipv6
    var id: String { "\(pid)-\(port)" }
}

struct PortBind: Sendable, Hashable {
    let address: String          // "*", "127.0.0.1", "::1", "fe80::1%en0", ...
    let family: AddressFamily
}

enum AddressFamily: String, Sendable, Hashable { case ipv4 = "IPv4", ipv6 = "IPv6" }

enum SignalResult: Sendable, Equatable {
    case success
    case failure(POSIXErrorCode)
}
```

#### Service surface (in `Services/PortScanner.swift`)

```swift
protocol PortScanning: Sendable {
    func scanTCPListening() async throws -> [PortRecord]
    func kill(pid: pid_t, signal: Int32) -> SignalResult
}

actor PortScanner: PortScanning {
    func scanTCPListening() async throws -> [PortRecord]
    nonisolated func kill(pid: pid_t, signal: Int32) -> SignalResult {
        if Darwin.kill(pid, signal) == 0 { return .success }
        let code = POSIXErrorCode(rawValue: errno) ?? .EINVAL
        return .failure(code)
    }
}

enum PortScanError: Error, Equatable {
    case lsofTimeout
    case lsofFailed(exitCode: Int32, stderr: String)
    case parseFailed(line: String)
}
```

Capturing `errno` **immediately after** the `Darwin.kill` call (before any other syscall can clobber it) is the entire reason the result type carries the code.

#### Subprocess runner

The existing `ShellRunner` calls `pipe.fileHandleForReading.readToEnd()` after the process has already exited, which deadlocks once stdout exceeds the pipe buffer (~16 KiB). `lsof` listing 50–200 open TCP files reliably exceeds that.

`PortScanner` defines a `SubprocessRunning` protocol so the runner can be stubbed in tests (the "lsof exit 1 with empty stdout/stderr" case lives at the runner layer, not the parser layer):

```swift
protocol SubprocessRunning: Sendable {
    func run(
        path: String, args: [String], timeout: Duration
    ) async throws -> SubprocessResult
}

struct SubprocessResult: Sendable, Equatable {
    let stdout: String
    let stderr: String
    let exit: Int32
    let timedOut: Bool
}

enum SubprocessError: Error, Equatable {
    case spawnFailed(String)
}
```

`PortScanner.init(runner:)` accepts any `any SubprocessRunning` (defaulting to the real one). Tests inject a stub that returns canned `SubprocessResult` values.

The real implementation drains pipes concurrently with the running process and honors both timeout and Task cancellation:

```swift
struct LsofRunner: SubprocessRunning {
    func run(
        path: String, args: [String], timeout: Duration
    ) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() }
        catch { throw SubprocessError.spawnFailed("\(error)") }

        // Honor cancellation: if the awaiting Task is cancelled, terminate
        // the child. The read async-lets then hit EOF and unblock.
        return try await withTaskCancellationHandler {
            // Drain pipes concurrently so the kernel buffer never fills.
            async let outData: Data = readAll(outPipe.fileHandleForReading)
            async let errData: Data = readAll(errPipe.fileHandleForReading)

            // Timeout watchdog terminates the child on deadline.
            let timedOut = ManagedAtomic(false)   // or actor-isolated Bool
            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                if process.isRunning {
                    timedOut.store(true, ordering: .relaxed)
                    process.terminate()
                }
            }

            let (out, err) = await (outData, errData)
            watchdog.cancel()
            process.waitUntilExit()   // already returned; ensures status set

            return SubprocessResult(
                stdout: String(data: out, encoding: .utf8) ?? "",
                stderr: String(data: err, encoding: .utf8) ?? "",
                exit: process.terminationStatus,
                timedOut: timedOut.load(ordering: .relaxed)
            )
        } onCancel: {
            // Called when the *outer* Task is cancelled. Process.terminate()
            // is thread-safe.
            if process.isRunning { process.terminate() }
        }
    }
}
```

`scanTCPListening()` inspects `SubprocessResult.timedOut` first; when true it throws `PortScanError.lsofTimeout` regardless of exit status. When false, it applies the empty-result rule (exit 1 + empty stdout/stderr → `[]`) and otherwise the failure rule.

`LsofRunner` lives in `PortScanner.swift` alongside the actor; other features keep using `ShellRunner` for their short outputs. `Bool`-flag implementation detail can use `os_unfair_lock` or actor isolation if `ManagedAtomic` is overkill — the point is "the runner returns whether it timed out, the scanner branches on it."

#### Scanning pipeline

1. Run `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -F pPcntL +c 0` with a 3-second timeout via the private runner.
   - `-F pPcntL` requests fielded output: `p` = process id, `P` = protocol name, `c` = command name, `n` = name (`addr:port`), `t` = file type (`IPv4` / `IPv6`), `L` = login user. **`t` is the address family field — `P` is the protocol (`TCP`), not the family.**
   - `-n -P` skips DNS / service-name resolution.
   - `+c 0` disables command-name truncation.
2. **Handle empty-result exit code.** lsof returns exit code 1 with empty stdout and (typically) empty stderr when no matching open files exist. Treat `(exit == 1 && stdout.isEmpty)` as a successful empty scan, not a failure. Any other non-zero exit with non-empty stderr is a real error → `PortScanError.lsofFailed`.
3. Parse the fielded output by process record (`p`-prefixed line starts a new process) → file record (`f`-prefixed line starts a new file within a process). Extract `(pid, command, addr:port, family)`. Address parsing handles three forms: `*:5000`, `127.0.0.1:3000`, `[::1]:8080` (and zone-id variants like `[fe80::1%en0]:1234`).
4. Group entries by `(pid, port)`. Each group becomes a single `PortRecord` whose `binds` array preserves every distinct `(address, family)` pair. **No information is lost when both IPv4 `127.0.0.1` and IPv6 `[::1]` listen on the same port.**
5. Enrich with `sysctl(KERN_PROCARGS2)` once per unique pid (deduplicated across multi-port processes) to obtain `executablePath` and `commandLine`. Failures (permission denied, process gone) are silent — the record keeps lsof's short command name.
6. Return `[PortRecord]` unsorted; the inventory sorts at the view layer.

The parser is exposed as a free function `parseLsofOutput(_ raw: String) throws -> [PortRecord]` to enable fixture-based unit tests without spawning lsof.

#### Kill

`scanner.kill(pid, signal)` returns `SignalResult.success` on `Darwin.kill == 0`, otherwise `.failure(POSIXErrorCode)` with `errno` captured immediately. The actor does **not** implement the SIGTERM → SIGKILL fallback — that lives in `PortInventory` as a policy decision.

### 4. `PortInventory` (`@MainActor @Observable`)

File: `Sources/AnyDoor/Services/PortInventory.swift`

```swift
@MainActor
@Observable
final class PortInventory {
    static let shared = PortInventory()

    private(set) var records: [PortRecord] = []
    private(set) var isRefreshing = false
    private(set) var lastError: PortInventoryError? = nil
    private(set) var killingPIDs: Set<pid_t> = []
    private(set) var failedKillPIDs: [pid_t: KillFailure] = [:]

    var viewMode: ViewMode {
        didSet {
            UserDefaults.standard.set(viewMode.rawValue, forKey: Self.viewModeKey)
        }
    }
    var searchText: String = ""

    init(scanner: any PortScanning = PortScanner()) { ... }

    func refresh() async
    func kill(pid: pid_t) async
    func dismissError(for pid: pid_t)
}

enum ViewMode: String { case list, tree }

enum PortInventoryError: Equatable, Sendable {
    case scanFailed(String)
}

struct KillFailure: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case permissionDenied
        case processGone
        case other(Int32)
    }
    let reason: Reason
    let timestamp: Date
}
```

#### Refresh

- Entry points: popover `.task`, ⌘R, automatic after a kill.
- Concurrency model: a monotonically incrementing `refreshGeneration: UInt64` token plus an `inflightCount: Int` counter:
  1. Each `refresh()` call increments `refreshGeneration`, captures `let myGen = refreshGeneration`, increments `inflightCount`, and sets `isRefreshing = true`.
  2. Awaits the scanner. The scanner's subprocess runner is responsible for terminating the lsof child on cancellation or timeout (see the runner sketch above) — Swift's `Task.cancel` alone does not kill a running `Process`.
  3. After awaiting: decrement `inflightCount`. Then:
     - `guard myGen == refreshGeneration else { isRefreshing = (inflightCount > 0); return }` — stale completion is discarded but the spinner remains on if a newer scan is still running.
     - On the latest generation, write `records` / `lastError` and set `isRefreshing = (inflightCount > 0)`.
- The rule that matters: **`isRefreshing = false` happens only when no scans are in flight**, regardless of whether the resolved one was the latest. This prevents a stale early completion from clearing the spinner while the newest scan is still running.
- On failure, `lastError` is set and `records` is preserved. A stale failure does not overwrite a fresh success (same generation-token gate).
- We do **not** try to cancel the old subprocess on a new request — lsof is fast enough (~tens of ms) that the simple "newest wins" rule is sufficient. The runner's task-cancellation handler exists for the harder case (popover dismissed mid-scan) where the parent Task itself gets cancelled.

#### Kill policy (two-phase)

Kill is **pid-level by design**. When the user clicks the kill icon on a port row, the inventory looks up the pid for that port and signals the entire process. Consequently, if a process listens on multiple ports, killing one row removes all of them on the next refresh. This is intentional — the UI never partially signals a process — and surfaces consistently in both list and tree views.

```
1. killingPIDs.insert(pid)
2. let result = scanner.kill(pid, SIGTERM)
3. switch result:
   case .failure(.ESRCH):
       // Process already gone — treat as success.
       await refresh()
       killingPIDs.remove(pid)
       return
   case .failure(let code):
       let reason: KillFailure.Reason =
           (code == .EPERM) ? .permissionDenied : .other(code.rawValue)
       failedKillPIDs[pid] = KillFailure(reason: reason, timestamp: .now)
       schedule3sDismiss(for: pid)
       killingPIDs.remove(pid)
       return
   case .success:
       break  // continue to step 4
4. try? await Task.sleep(for: .milliseconds(500))
5. await refresh()
6. if records still contains pid:
       let escalate = scanner.kill(pid, SIGKILL)
       switch escalate:
         case .success: try? await Task.sleep(for: .milliseconds(200)); await refresh()
         case .failure(.ESRCH): await refresh()
         case .failure(let code):
             let reason: KillFailure.Reason =
                 (code == .EPERM) ? .permissionDenied : .other(code.rawValue)
             failedKillPIDs[pid] = KillFailure(reason: reason, timestamp: .now)
             schedule3sDismiss(for: pid)
7. killingPIDs.remove(pid)
```

`errno` is captured by `SignalResult.failure(POSIXErrorCode)`, then mapped to `KillFailure.Reason`. **`ESRCH` is never recorded as a failure** — at any stage where it occurs (either initial SIGTERM or SIGKILL escalation) the inventory treats it as the process having already exited and just refreshes. Because failure is recorded by pid, every row of the affected process shows the red indicator until the auto-dismiss timer fires (3s) or the user dismisses it.

#### Derived views

```swift
var filteredRecords: [PortRecord] {
    guard !searchText.isEmpty else {
        return records.sorted { $0.port < $1.port }
    }
    let q = searchText.lowercased()
    var seen = Set<PortRecord.ID>()
    var ordered: [PortRecord] = []
    func append(_ bucket: [PortRecord]) {
        for r in bucket where !seen.contains(r.id) {
            seen.insert(r.id); ordered.append(r)
        }
    }
    append(records.filter { String($0.port).contains(q) })
    append(records.filter { $0.processName.lowercased().contains(q) })
    append(records.filter { String($0.pid).contains(q) })
    return ordered
}

var groupedByProcess: [ProcessGroup] {
    Dictionary(grouping: filteredRecords, by: \.pid)
        .map { ProcessGroup(pid: $0.key,
                            processName: $0.value.first!.processName,
                            ports: $0.value.sorted { $0.port < $1.port }) }
        .sorted { $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending }
}

struct ProcessGroup: Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let processName: String
    let ports: [PortRecord]
}
```

### 5. UI layer

#### `PortManagerPopoverView`

File: `Sources/AnyDoor/Views/PortManagerPopoverView.swift`

Structure:

```swift
struct PortManagerPopoverView: View {
    @Bindable var inventory: PortInventory   // the singleton
    var onHoverChange: (Bool) -> Void        // callback to HoverGate.popoverHover

    var body: some View {
        VStack(spacing: 0) {
            PortManagerHeader(inventory: inventory)
            if let err = inventory.lastError {
                ScanErrorBanner(error: err, retry: { await inventory.refresh() })
            }
            Group {
                if inventory.isRefreshing && inventory.records.isEmpty {
                    ProgressView("扫描中...")
                } else if inventory.filteredRecords.isEmpty {
                    Text("无匹配的端口").foregroundStyle(.secondary)
                } else {
                    switch inventory.viewMode {
                    case .list: PortListView(inventory: inventory)
                    case .tree: PortTreeView(inventory: inventory)
                    }
                }
            }
            Divider()
            PortManagerToolbar(inventory: inventory)
        }
        .frame(width: 340)
        .frame(minHeight: 280, maxHeight: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { await inventory.refresh() }
        .onHover(perform: onHoverChange)   // critical: keeps popover open while hovered
        .background(KeyboardMonitor(inventory: inventory))
    }
}
```

The `onHoverChange` callback mirrors `AppShortcutsPopoverView.swift:51` and feeds into `HoverGate.popoverHover(_:)`. Without it, the gate only tracks the trigger row's hover state, and the popover closes 300ms after the cursor leaves the menu bar row even though the cursor is inside the popover. `MenuBarView` is responsible for wiring this callback when it constructs the view (just like it does for App Shortcuts today).

#### `PortListView` / `PortRowView`

- One row per `PortRecord`, sorted by port ascending.
- Layout: `[status dot] [:port monospaced] [process name] [PID xxxxx] [kill icon on hover]`
- Bind addresses (`record.binds`) are surfaced via tooltip on hover (`help(...)` modifier). The tooltip string format: `"\(processName)\n\(commandLine ?? "")\n\nBinds:\n\(binds.map { "\($0.address) (\($0.family.rawValue))" }.joined(separator: "\n"))"`. The list row stays compact (matches the mockup) — binds are surfaced on demand, not in the primary visual.
- Status dot: green (default), gray + spinner (killing), red (failed).
- Process name truncates tail.
- Kill icon: `xmark.circle.fill`, hidden until row hover; replaced by spinner while `killingPIDs` contains the pid; replaced by `exclamationmark.circle.fill` (red) while `failedKillPIDs` contains the pid.
- Tap kill → `Task { await inventory.kill(pid: record.pid) }`.

#### `PortTreeView` / process group rendering

- One `DisclosureGroup` per `ProcessGroup`, all collapsed by default.
- Group header: `[chevron] [status dot] [process name] [PID xxxxx] [collapsed-only: port count capsule] [kill icon on hover]`.
- Leaf rows: `[:port monospaced] [bind summary]`. The bind summary is computed from `record.binds`:
  - 1 bind → `"\(bind.address)"` (e.g. `*`, `127.0.0.1`, `[::1]`).
  - 2 binds, exactly one IPv4 and one IPv6 → `"\(ipv4.address) · \(ipv6.address)"` (typical dual-stack case; matches the mockup's "* · :5000" intent except now driven by real data).
  - More than 2 → `"\(binds.count) binds"` with tooltip listing them in full.
- Leaf rows still have **no** kill icon (per earlier decision).
- Tap group's kill icon → `Task { await inventory.kill(pid: group.pid) }`.
- Expansion state in `@State` only; not persisted.

#### `PortManagerHeader`

- Left: SF Symbol `globe` (matches mockups).
- Middle: search field, auto-focused on appear; `@FocusState` binding.
- Right: count capsule showing `filteredRecords.count`, accompanied by a small spinner when `isRefreshing` is true.

**Window key-focus contract.** The existing `HoverPopover` (`HoverPopover.swift:14`) hosts content in a borderless, `level = .floating` `NSWindow` that is shown with `orderFrontRegardless()`. A bare `NSWindow` like that returns `false` from `canBecomeKey` and therefore swallows text input and local key events — fine for App Shortcuts (read-only rows with tap gestures), broken for port-manager (search field + ⌘R / ⌘T / ESC). Two changes are required and **must land in the same iteration as this feature**:

1. Subclass `NSWindow` (or set `setIsVisible(false)` and reconfigure) so `canBecomeKey` and `canBecomeMain` return `true`. Add `becomesKeyOnlyIfNeeded = true` and `styleMask` includes `.nonactivatingPanel`-style behavior (use `NSPanel` if simpler) so opening the popover does not steal app activation from the foreground app — this matches the existing "menu bar accessory" feel.
2. In `HoverPopover.show(...)`, call `window.makeKey()` (or `makeKeyAndOrderFront(nil)` followed by `NSApp.activate(ignoringOtherApps: false)`) so the SwiftUI `@FocusState` binding can claim first responder.

App Shortcuts is unaffected: it has no focusable controls, so gaining key status is harmless. Add a manual QA check that hovering App Shortcuts still doesn't show a typing cursor and doesn't steal focus from other apps.

If subclassing turns out fragile, the fallback is a second, port-manager-specific popover host that owns an `NSPanel` configured for key acceptance, and `HoverPopover` stays read-only. The spec leaves room for either path during implementation; the contract that must hold is "the search field is focused on appear and receives keystrokes without forcing AnyDoor to the foreground."

#### `PortManagerToolbar`

- Two horizontal rows or a single divided footer matching the mockups: `Refresh ⌘R` and `Tree View ⌘T` (label flips to `List View ⌘T` when in tree mode).

#### Keyboard handling

A local `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` mounted while the popover is visible:

- `⌘R` → `Task { await inventory.refresh() }`
- `⌘T` → `inventory.viewMode = (inventory.viewMode == .list) ? .tree : .list`
- `ESC`: if `searchText` is non-empty, clear it; otherwise close the popover via the `HoverPopover` handle.

### 6. `HoverPopover` integration

`MenuBarView` already dispatches hover for `.appShortcuts`. Extend the dispatch (real API: `entry.source` is the `PanelEntrySource` enum, not `entry.builtin`):

```swift
if case let .builtin(item) = entry.source {
    switch item {
    case .appShortcuts: popover.updateContent { AppShortcutsPopoverView(...) }
    case .portManager:  popover.updateContent { PortManagerPopoverView(...) }
    default: break
    }
}
```

Reuse `HoverGate` timing (400ms enter, 300ms leave) and `HoverPopover` placement (right-anchored, flips left on screen edges).

The existing `MenuBarView` already maintains a single `triggerFrame` for the App Shortcuts row (`MenuBarView.swift:62`). To support a second hoverable row, that state is generalised into a small dictionary `[BuiltinItem: CGRect]` (or two named optionals — judgement call during implementation) so each submenu row can record its own anchor. `HoverGate` is also parametrised by the currently-hovered item so the popover can mount the right content. This is the only structural change to `MenuBarView`; no new windows, no new gestures.

## Data Flow

```
User hover on port-manager row
  └─> HoverGate.shouldShow = true after 400ms
       └─> HoverPopover.present(PortManagerPopoverView)
            └─> .task { await PortInventory.shared.refresh() }
                 └─> PortScanner.scanTCPListening()
                      ├─> private subprocess runner: lsof -nP -iTCP -sTCP:LISTEN -F pPcntL +c 0
                      │     (drains stdout/stderr concurrently with run; 3s timeout)
                      ├─> handle (exit==1 && stdout.isEmpty) → return []
                      ├─> parseLsofOutput → [(pid,port,binds[],family)]
                      └─> sysctl(KERN_PROCARGS2) per unique pid
                 └─> PortInventory.records = ...
                      └─> SwiftUI re-renders PortListView / PortTreeView

User clicks kill on a row
  └─> PortInventory.kill(pid:)
       ├─> killingPIDs.insert(pid)  → all rows of that pid turn gray + spinner
       ├─> scanner.kill(pid, SIGTERM)
       │    └─ failure → failedKillPIDs[pid] = ...  → all rows of that pid turn red
       ├─> sleep 500ms
       ├─> refresh()
       ├─> if still alive: scanner.kill(pid, SIGKILL) → refresh()
       └─> killingPIDs.remove(pid)
```

## Error Handling

| Error | Surface | Recovery |
|-------|---------|----------|
| `lsof` exit 1 with empty stdout/stderr | Treated as a successful empty scan: `records = []`, no banner. | N/A (expected when no TCP listeners exist). |
| `lsof` timeout / other non-zero exit / parse failure | Inline yellow banner above the list ("刷新失败: ..."), retry button. Last records preserved. | Manual ⌘R or banner retry button. |
| `lsof` subprocess hangs past timeout | Subprocess runner terminates the child and surfaces `.lsofTimeout`. | Manual ⌘R. |
| Stale scan completion arrives after a newer one | Generation token discards the stale result. | Automatic. |
| Kill returns `.failure(.EPERM)` | Red `exclamationmark.circle.fill` on every row of that pid, tooltip "权限不足（系统/其他用户进程）", auto-dismiss after 3s. | None (no privilege escalation). |
| Kill returns `.failure(.ESRCH)` | Treated as success, no UI error. Refresh removes the row(s). | Automatic. |
| Kill returns other `.failure(code)` | Same red indicator, tooltip "kill 失败 (errno: <code>)". | Manual retry. |
| SIGKILL escalation fails | Red indicator with the escalation errno; row remains in the list until next manual action. | Manual retry. |
| Popover opens with empty records | Centered `ProgressView("扫描中...")`. | Automatic on scan completion. |
| Filtered records empty | Centered "无匹配的端口" text. | Adjust search. |
| Duplicate kill clicks on same pid | Kill icon disabled (rows gray) while `killingPIDs` contains pid. | N/A. |

Logging: `os.Logger(subsystem: "dev.bybee.AnyDoor", category: "PortInventory")` records scan start/end/failure and kill calls (pid, signal, errno). Process names and command lines are not logged to avoid leaking user activity.

## Testing

### Package change

`Package.swift` already declares an `AnyDoorTests` target. The change required is **modifying** that target to enable bundling fixture files:

```swift
.testTarget(
    name: "AnyDoorTests",
    dependencies: ["AnyDoor"],
    resources: [.process("Fixtures")],            // ← add this line
    swiftSettings: [.swiftLanguageMode(.v6)]
)
```

Fixtures live under `Tests/AnyDoorTests/Fixtures/`. Tests load them with `Bundle.module.url(forResource:...)`. Short fixtures can also live inline as multiline string literals when the file would be only a handful of lines.

### `PortScannerTests` (unit, no system dependency)

`parseLsofOutput` fixtures (one assertion per fixture):

- Single process, single IPv4 listener (`tIPv4` field present).
- Single process, multiple ports (verifies file-record grouping under one process record).
- Same `(pid, port)` listening on both IPv4 and IPv6 → one `PortRecord` whose `binds` contains both families with their respective addresses (`127.0.0.1` and `::1`).
- Multiple distinct bind addresses on the same port (e.g. a server binding both `127.0.0.1:5000` and `0.0.0.0:5000`) → one record with multiple binds.
- IPv6 zone-id parsing (`[fe80::1%en0]:1234`).
- Command name containing a space (e.g. `Google Chrome Helper`) preserved verbatim with `+c 0`.
- Command name containing lsof's `\xHH` escape sequences (lsof escapes non-printable bytes); spec'd behaviour: decode escapes back to the original byte before constructing the string.
- `exit == 1, stdout.isEmpty, stderr.isEmpty` → parser returns `[]` (this is tested at the scanner-runner layer with a stubbed runner).
- Malformed input (truncated record, missing required field) → throws `PortScanError.parseFailed`.

`parseProcArgs` fixture: simulated `KERN_PROCARGS2` byte buffer; verify executable path and argv extraction.

### `PortInventoryTests` (`@MainActor`, stub `PortScanning`)

- Search priority: records covering port `:3000`, process `node`, PID `67035`; query `"30"` returns the port-match first, then the PID match.
- Search is case-insensitive.
- `viewMode` round-trips through `UserDefaults` (isolated suite name per test).
- Successful kill: stub returns `.success` → `killingPIDs` cleared after refresh; records updated.
- SIGTERM `.failure(.EPERM)` → `failedKillPIDs[pid].reason == .permissionDenied`; auto-dismiss timer removes it.
- SIGTERM `.failure(.ESRCH)` → **not** in `failedKillPIDs`; refresh is still triggered.
- SIGTERM `.success` but process persists in next scan → stub records a second kill call with `SIGKILL`.
- SIGKILL escalation `.failure(.EPERM)` → records `failedKillPIDs` with that errno.
- Refresh generation token: consecutive `refresh()` calls where the older one resolves later → records reflect only the newer scan's data (stub controls resolution order via `CheckedContinuation`).
- `groupedByProcess` returns groups sorted by name with ports sorted ascending.
- Submenu hotkey filtering remains unchanged: `PanelStore.rebuildHotkeySnapshots()` produces zero snapshots for `.portManager` regardless of whether the preference has a keycode set (regression guard since `.portManager` is the first new submenu item).
- `isRefreshing` semantics with concurrent refreshes: stub runner exposes two `CheckedContinuation`s. Trigger `refresh()` twice; resolve the older one first; assert `isRefreshing == true` (newer scan still in flight); resolve the newer; assert `isRefreshing == false`. Reverse order also covered.
- Subprocess runner timeout: stub runner returns `SubprocessResult(timedOut: true, ...)`; scanner throws `.lsofTimeout` regardless of exit code.
- Subprocess runner cancellation: real `LsofRunner` test (best-effort; skip if CI cannot spawn `/usr/bin/yes`) — spawn `/usr/bin/yes`, wrap in a Task, cancel after 100ms, assert the process is no longer running shortly after.

### Manual QA checklist

- Hover the App Shortcuts row → port-manager popover does **not** appear.
- Hover the port-manager row → popover appears after ~400ms.
- Search field receives focus on appear and accepts typing **without** bringing AnyDoor to the foreground (verify by hovering with another app key — the other app's title bar should not lose key state).
- Move cursor from the menu bar row into the popover → popover stays open (no flicker, no close after 300ms).
- Move cursor out of the popover entirely → popover closes after ~300ms.
- Toggle list/tree → preference persists after app restart.
- Type in search → count updates instantly; ordering matches priority spec.
- Tooltip on a list row shows the bind addresses; for a dual-stack listener, both IPv4 and IPv6 entries are listed.
- Tree view leaf row shows a sensible bind summary (single, dual, or "N binds") matching `record.binds`.
- Click kill on a user-owned process → row turns gray, process disappears after 0.5–1s, list refreshes.
- Click kill on a root-owned process (e.g. `ControlCenter`) → red icon + tooltip, auto-dismisses after 3s.
- ESC clears search when non-empty; ESC closes popover when search is empty.
- ⌘R triggers refresh; banner appears and disappears on transient failures.
- ⌘T toggles list/tree view.
- Open Settings → port-manager row shows no hotkey recorder (column reserved blank, matching App Shortcuts).

### Out of scope for tests

- `lsof` integration (treated as trusted system tool).
- SwiftUI rendering (no snapshot library).
- `HoverPopover` plumbing (already validated in App Shortcuts).
- UI automation.

## Files Touched / Created

**Created**
- `Sources/AnyDoor/Models/PortRecord.swift` — `PortRecord`, `PortBind`, `AddressFamily`, `SignalResult`.
- `Sources/AnyDoor/Services/PortScanner.swift` — actor, `PortScanning` protocol, private subprocess runner, free function `parseLsofOutput`.
- `Sources/AnyDoor/Services/PortInventory.swift` — `@MainActor @Observable` store, refresh generation token, kill policy.
- `Sources/AnyDoor/Views/PortManagerPopoverView.swift`
- `Sources/AnyDoor/Views/PortListView.swift` + `PortRowView.swift` (shared row visuals).
- `Sources/AnyDoor/Views/PortTreeView.swift` (group-header rendering may live inline if it stays small; promote to a separate `PortProcessGroupView.swift` if it grows past ~40 lines).
- `Tests/AnyDoorTests/PortScannerTests.swift`
- `Tests/AnyDoorTests/PortInventoryTests.swift`
- `Tests/AnyDoorTests/Fixtures/lsof-*.txt`

**Modified**
- `Sources/AnyDoor/Models/BuiltinItem.swift` — add `.portManager` case with `.submenu` kind, title, symbol, default ordering.
- `Sources/AnyDoor/Services/PanelStore.swift` — no behavioural change required for hotkey path; verify the existing submenu filter still applies (regression test in `PortInventoryTests`).
- `Sources/AnyDoor/Views/MenuBarView.swift` — generalise the single `triggerFrame` into per-submenu-item frames; extend the hover dispatch to mount `PortManagerPopoverView` for `.portManager`.
- `Sources/AnyDoor/Views/HoverPopover.swift` — allow the underlying `NSWindow` to accept key focus (subclass override / `NSPanel` swap / opt-in flag) so the SwiftUI `@FocusState` on the search field can become first responder. Existing `AppShortcutsPopoverView` is unaffected because it has no focusable controls.
- `Sources/AnyDoor/Views/PanelSettingsView.swift` — generalise the hotkey-column filter at `:92` from `case .builtin(.appShortcuts)` to "any `.submenu`-kind builtin" so the new port-manager row does not present a recorder that the system ignores.
- `Package.swift` — augment the existing `AnyDoorTests` target with `resources: [.process("Fixtures")]`.

**Not modified (despite earlier draft saying otherwise)**
- `Sources/AnyDoor/Models/HotkeyAction.swift` — no new case; global hotkey deferred.

No SwiftData schema changes (preference for `.portManager` is auto-seeded by the existing seeder).

## Open Questions

None. All clarifications captured above.

## Future Extensions (not in this design)

- Global hotkey that opens the menu bar + mounts the port-manager popover with search focused. Requires a new presenter path because the current architecture only resolves submenu popovers when the menu bar panel is already on screen.
- Copy port / PID / command line to clipboard via context menu.
- Pin specific ports as favorites for quick access.
- Show CPU / memory next to each process.
- Background polling with delta animations.
- UDP / established connections via a view-mode segmented control.
- Keyboard navigation inside the list.

## Revisions

**2026-05-21 — second-round revisions**

- Documented that `HoverPopover`'s current `NSWindow` is not key-eligible. The port-manager popover requires text input + local hotkeys, so the popover host must be modified (subclass / `NSPanel` / opt-in flag) to accept key focus without stealing app activation. Bundled in the same iteration.
- Generalised the hotkey-column filter in `PanelSettingsView` from `case .builtin(.appShortcuts)` to "any submenu-kind builtin" so the port-manager row does not display a recorder the system silently ignores.
- Added the `onHoverChange` callback wiring on `PortManagerPopoverView` (mirroring `AppShortcutsPopoverView.swift:51`) so the popover keeps the `HoverGate` aware of cursor presence and does not close after 300ms when the cursor moves from the menu row into the popover.
- Subprocess runner: introduced `SubprocessRunning` protocol + `SubprocessResult.timedOut` flag; the scanner now branches on `timedOut` to throw `.lsofTimeout` deterministically. Added `withTaskCancellationHandler` so the lsof child is terminated when the awaiting Task is cancelled.
- Made the runner injection-friendly: `PortScanner.init(runner: any SubprocessRunning = LsofRunner())`. Lets the tests cover the "exit 1 + empty" rule and the timeout rule with a stub runner instead of spawning lsof.
- UI bind display: list row tooltip lists every bind with its family; tree leaf row renders a deterministic bind summary (1 / 2 / >2 cases) drawn from `record.binds` instead of a single string.
- Refresh concurrency: explicit `inflightCount` companion to the generation token so a stale early completion does not clear `isRefreshing` while a newer scan is still running.
- Swift 6 / API correctness: `any PortScanning` for the existential; `MenuBarView` switch keys on `entry.source` (the real API) via `if case let .builtin(item) = entry.source`.

**2026-05-21 — post-review revisions (first round)**

- Replaced `ShellRunner` usage in `PortScanner` with a dedicated subprocess runner that drains stdout/stderr concurrently with `process.run()`. `ShellRunner` reads the pipe only after `waitUntilExit`, which deadlocks once lsof's output exceeds the kernel pipe buffer (~16 KiB).
- Corrected the lsof field characters: `-F pPcntL` (the `t` field carries IPv4/IPv6; `P` is the protocol name, not the family).
- Replaced `(bindAddress: String, families: Set<AddressFamily>)` with `binds: [PortBind]` so dual-stack and multi-bind listeners do not lose addresses.
- Changed `kill(pid:signal:)` return type from `Bool` to `SignalResult` carrying a `POSIXErrorCode`. `errno` is captured immediately after the syscall. The kill pseudocode now branches on the result enum, and `ESRCH` is handled as success at every stage (no longer routed through the failure branch).
- Removed `HotkeyAction.showSubmenu` and the global-hotkey flow from the current scope. Listed it under Future Extensions.
- Generalised the single `triggerFrame` in `MenuBarView` into per-submenu frames so the App Shortcuts and port-manager rows can both anchor a popover.
- Refresh concurrency: replaced "new refresh cancels the previous" with a generation-token model. Documented that Swift `Task.cancel()` does not terminate a child subprocess and pushed responsibility for that into the subprocess runner.
- Error handling: `lsof exit 1 + empty stdout/stderr` is now defined as a successful empty scan.
- Tests: corrected the Package.swift instruction (the test target already exists; only `resources` are added). Added fixtures for multi-bind, IPv6 zone-id, command-name spaces, lsof's `\xHH` escape, the exit-1-empty case, SIGKILL fallback paths, and a regression test that submenu hotkey snapshots remain filtered out.
- Added `Sources/AnyDoor/Models/PortRecord.swift` as a dedicated domain-model file so `PortScanner.swift` does not own shared types.
