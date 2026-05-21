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

`PortScanner` ships its own private runner that drains pipes concurrently with the running process. Sketch:

```swift
private func runProcess(
    path: String, args: [String], timeout: Duration
) async throws -> (stdout: String, stderr: String, exit: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let outPipe = Pipe(), errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()

    // Drain pipes on detached tasks so the kernel buffer never fills.
    async let outData = readAll(outPipe.fileHandleForReading)
    async let errData = readAll(errPipe.fileHandleForReading)

    // Timeout watchdog terminates the process. The read tasks then finish
    // naturally because the file handles hit EOF.
    let watchdog = Task {
        try? await Task.sleep(for: timeout)
        if process.isRunning { process.terminate() }
    }

    let (out, err) = await (outData, errData)
    watchdog.cancel()
    process.waitUntilExit()  // already returned, but ensures status is set

    return (
        stdout: String(data: out, encoding: .utf8) ?? "",
        stderr: String(data: err, encoding: .utf8) ?? "",
        exit: process.terminationStatus
    )
}
```

The runner is private to `PortScanner` — other features keep using `ShellRunner` for short outputs.

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

    init(scanner: PortScanning = PortScanner()) { ... }

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
- Concurrency model: a monotonically incrementing `refreshGeneration: UInt64` token. Each `refresh()` call:
  1. Increments the generation and captures `let myGen = refreshGeneration`.
  2. Awaits the scanner. The scanner's subprocess runner is responsible for terminating the lsof child when its enclosing Task is cancelled or hits the timeout (see the runner sketch above) — Swift's `Task.cancel` alone does not kill a running `Process`.
  3. After awaiting, checks `guard myGen == refreshGeneration else { return }`. A stale completion is discarded; only the latest scan can overwrite `records`.
- On failure, `lastError` is set and `records` is preserved. (Staleness check still applies — a stale failure does not overwrite a fresh success.)
- A single in-flight scan is the steady state; overlapping refreshes are tolerated but only the newest result lands. We do **not** try to cancel the old subprocess on a new request — lsof is fast enough that the simple "newest wins" rule is sufficient.

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

```
VStack(spacing: 0) {
    PortManagerHeader(inventory: ...)        // globe icon + search + count
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
            case .list: PortListView()
            case .tree: PortTreeView()
            }
        }
    }
    Divider()
    PortManagerToolbar(inventory: ...)       // Refresh ⌘R / Toggle View ⌘T
}
.frame(width: 340)
.frame(minHeight: 280, maxHeight: 560)
.task { await inventory.refresh() }
.background(KeyboardMonitor(inventory: ...)) // local NSEvent monitor
```

#### `PortListView` / `PortRowView`

- One row per `PortRecord`, sorted by port ascending.
- Layout: `[status dot] [:port monospaced] [process name] [PID xxxxx] [kill icon on hover]`
- Status dot: green (default), gray + spinner (killing), red (failed).
- Process name truncates tail; tooltip shows `commandLine ?? processName`.
- Kill icon: `xmark.circle.fill`, hidden until row hover; replaced by spinner while `killingPIDs` contains the pid; replaced by `exclamationmark.circle.fill` (red) while `failedKillPIDs` contains the pid.
- Tap kill → `Task { await inventory.kill(pid: record.pid) }`.

#### `PortTreeView` / `PortProcessGroupView`

- One `DisclosureGroup` per `ProcessGroup`, all collapsed by default.
- Group header: `[chevron] [status dot] [process name] [PID xxxxx] [collapsed-only: port count capsule] [kill icon on hover]`.
- Leaf rows: `:port` + bind-address subtitle (`* · :5000` or `127.0.0.1 · :3000`); no kill icon on leaves.
- Tap group's kill icon → `Task { await inventory.kill(pid: group.pid) }`.
- Expansion state in `@State` only; not persisted.

#### `PortManagerHeader`

- Left: SF Symbol `globe` (matches mockups).
- Middle: search field, auto-focused on appear; `@FocusState` binding.
- Right: count capsule showing `filteredRecords.count`, accompanied by a small spinner when `isRefreshing` is true.

#### `PortManagerToolbar`

- Two horizontal rows or a single divided footer matching the mockups: `Refresh ⌘R` and `Tree View ⌘T` (label flips to `List View ⌘T` when in tree mode).

#### Keyboard handling

A local `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` mounted while the popover is visible:

- `⌘R` → `Task { await inventory.refresh() }`
- `⌘T` → `inventory.viewMode = (inventory.viewMode == .list) ? .tree : .list`
- `ESC`: if `searchText` is non-empty, clear it; otherwise close the popover via the `HoverPopover` handle.

### 6. `HoverPopover` integration

`MenuBarView` already dispatches hover for `.appShortcuts`. Extend the switch:

```swift
switch entry.builtin {
case .appShortcuts: present(AppShortcutsPopoverView())
case .portManager:  present(PortManagerPopoverView())
default: break
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

### Manual QA checklist

- Hover the App Shortcuts row → port-manager popover does **not** appear.
- Hover the port-manager row → popover appears after ~400ms.
- Toggle list/tree → preference persists after app restart.
- Type in search → count updates instantly; ordering matches priority spec.
- Click kill on a user-owned process → row turns gray, process disappears after 0.5–1s, list refreshes.
- Click kill on a root-owned process (e.g. `ControlCenter`) → red icon + tooltip, auto-dismisses after 3s.
- ESC clears search when non-empty; ESC closes popover when search is empty.
- ⌘R triggers refresh; banner appears and disappears on transient failures.
- ⌘T toggles list/tree view.

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

**2026-05-21 — post-review revisions**

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
