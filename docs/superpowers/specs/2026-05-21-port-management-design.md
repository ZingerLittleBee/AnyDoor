# Port Management — Design

**Date**: 2026-05-21
**Status**: Approved (design phase)
**Author**: Brainstorming session

## Summary

Add a "port management" entry to the AnyDoor menu bar panel that, on hover, surfaces a popover listing all TCP listening ports on the machine. Users can search by port / process name / pid, switch between a list view (sorted by port) and a tree view (grouped by process), and kill processes inline. The feature reuses the existing hover-popover infrastructure (`HoverPopover` + `HoverGate`) used by the "App Shortcuts" entry.

## Goals

- Show all TCP listening ports with port number, process name, pid, bind address.
- Provide search across port / process name / pid with priority ordering.
- Provide list and tree views; remember the chosen view across sessions.
- Provide one-click kill (SIGTERM → 500ms → SIGKILL fallback) with inline failure feedback when the kernel rejects the signal (typically root-owned processes).
- Reuse `BuiltinItem` infrastructure so the entry can be reordered, hidden, and bound to a global hotkey from the panel settings.

## Non-Goals

- No UDP, established TCP, or per-connection inspection.
- No privilege escalation (no `sudo`, no `osascript with administrator privileges`, no privileged helper). System processes that the kernel refuses to signal stay visible with a permission-denied indicator.
- No continuous background scanning; data refreshes when the popover opens or on user request.
- No persistence of search text or tree expansion state across sessions.
- No keyboard navigation inside the list (up/down arrows, enter-to-kill).

## Clarifications Captured

| Topic | Decision |
|-------|----------|
| Port scope | TCP listening only (`lsof -nP -iTCP -sTCP:LISTEN`) |
| IPv4/IPv6 dual-stack | Merge into one row (one entry per pid+port) |
| Kill mechanism | Darwin `kill(2)` direct syscall, SIGTERM → 500ms wait → SIGKILL fallback |
| Kill failure handling | Inline red icon + tooltip, auto-dismiss after 3s; no escalation prompt |
| Refresh strategy | Scan on popover open + manual ⌘R + auto-refresh after kill |
| Menu integration | New `BuiltinItem.portManager` with `kind = .submenu` |
| Hotkey action | New `HotkeyAction.showSubmenu(BuiltinItem)` (semantically distinct from `toggleBuiltin`) |
| Persistence | Only the list/tree toggle (`UserDefaults`); search text and tree expansion are session-only |
| Tree default state | All groups collapsed by default |
| Kill icon on tree leaf rows | Not shown; killing the process row kills the pid (and consequently all its ports) |
| Scanning state UI | Centered `ProgressView` with label, no skeleton |
| Scan failure UI | Inline banner above the list, keeps last results visible, has a retry button |

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
│    └─ kill(pid:signal:) -> Bool   (nonisolated)           │ │
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

### 2. `HotkeyAction.showSubmenu(BuiltinItem)`

New case in `Sources/AnyDoor/Models/HotkeyAction.swift`:

- Encoded as `"showSubmenu:<itemKey>"` for `HotkeySnapshot` serialization.
- `BuiltinItem.hotkeyAction()` returns `.showSubmenu(.portManager)` for items where `kind == .submenu`, and the existing `.toggleBuiltin` / `.runBuiltin` for the other kinds.
- `PanelStore.dispatch` gains a new case:
  ```
  case .showSubmenu(let item):
      // broadcast to the menu bar to open the popover for `item`
  ```
- The menu bar listens to a published `submenuOpenRequest: BuiltinItem?` (or equivalent SwiftUI binding) on `PanelStore` and responds by mounting the corresponding `HoverPopover`.

### 3. `PortScanner` (actor)

File: `Sources/AnyDoor/Services/PortScanner.swift`

```swift
protocol PortScanning: Sendable {
    func scanTCPListening() async throws -> [PortRecord]
    func kill(pid: pid_t, signal: Int32) -> Bool
}

actor PortScanner: PortScanning {
    func scanTCPListening() async throws -> [PortRecord]
    nonisolated func kill(pid: pid_t, signal: Int32) -> Bool
}

struct PortRecord: Sendable, Hashable, Identifiable {
    let port: UInt16
    let pid: pid_t
    let processName: String
    let executablePath: String?
    let commandLine: String?
    let bindAddress: String      // "*", "127.0.0.1", "::1", ...
    let families: Set<AddressFamily>
    var id: String { "\(pid)-\(port)" }
}

enum AddressFamily: Sendable, Hashable { case ipv4, ipv6 }

enum PortScanError: Error {
    case lsofTimeout
    case lsofFailed(exitCode: Int32, stderr: String)
    case parseFailed(line: String)
}
```

#### Scanning pipeline

1. Run `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -F pPcnL +c 0` via the existing `ShellRunner` with a 3-second timeout.
   - `-F pPcnL` requests fielded output: `p` = pid, `P` = protocol, `c` = command, `n` = name (`addr:port`), `L` = login user.
   - `-n -P` skips DNS / service-name resolution for performance.
   - `+c 0` disables command-name truncation.
2. Parse the fielded output by process group → file group, extract `(pid, command, addr:port, family)`.
3. Merge entries with identical `(pid, port)` and different address families into a single `PortRecord` whose `families` is a set.
4. Optionally enrich with `sysctl(KERN_PROCARGS2)` for each unique pid to obtain `executablePath` and full `commandLine`. Failures (permission, race) are silent — the record falls back to lsof's command name.
5. Return `[PortRecord]` unsorted; the inventory sorts at the view layer.

The parser is exposed as a `static func parseLsofOutput(_ raw: String) throws -> [PortRecord]` to enable fixture-based unit tests.

#### Kill

`Darwin.kill(pid, signal) == 0` returns success. The actor does **not** implement the SIGTERM → SIGKILL fallback — that lives in `PortInventory` as a policy decision.

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
- Holds a `currentTask: Task<Void, Never>?`; a new refresh cancels the previous.
- On failure, `lastError` is set and `records` is preserved.

#### Kill policy (two-phase)

Kill is **pid-level by design**. When the user clicks the kill icon on a port row, the inventory looks up the pid for that port and signals the entire process. Consequently, if a process listens on multiple ports, killing one row removes all of them on the next refresh. This is intentional — the UI never partially signals a process — and surfaces consistently in both list and tree views.

```
1. killingPIDs.insert(pid)
2. ok = scanner.kill(pid, SIGTERM)
3. if !ok:
     classify errno → failedKillPIDs[pid] = KillFailure(reason: ...)
     start a 3-second detached Task to remove the entry
     killingPIDs.remove(pid)
     return
4. sleep 500ms
5. await refresh()
6. if records still contains pid:
     scanner.kill(pid, SIGKILL)
     sleep 200ms
     await refresh()
7. killingPIDs.remove(pid)
```

`errno` classification: `EPERM` → `.permissionDenied`, `ESRCH` → `.processGone` (treated as success, no error surfaced), anything else → `.other(errno)`. Because failure is recorded by pid, every row of the affected process shows the red indicator until the auto-dismiss timer fires (3s) or the user dismisses it.

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

When the global hotkey for `.portManager` fires, `PanelStore.dispatch(.showSubmenu(.portManager))` publishes the submenu open request, the menu bar opens its panel, then mounts the popover for that item with search focused.

## Data Flow

```
User hover on port-manager row
  └─> HoverGate.shouldShow = true after 400ms
       └─> HoverPopover.present(PortManagerPopoverView)
            └─> .task { await PortInventory.shared.refresh() }
                 └─> PortScanner.scanTCPListening()
                      ├─> ShellRunner: lsof ...
                      ├─> parseLsofOutput
                      └─> sysctl(KERN_PROCARGS2) per pid
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
| `lsof` timeout / non-zero exit / parse failure | Inline yellow banner above the list ("刷新失败: ..."), retry button. Last records preserved. | Manual ⌘R or banner retry button. |
| Kill returns `EPERM` | Red `exclamationmark.circle.fill` on the row, tooltip "权限不足（系统/其他用户进程）", auto-dismiss after 3s. | None (no privilege escalation). |
| Kill returns `ESRCH` | Treated as success, no UI error. Refresh removes the row. | Automatic. |
| Kill returns other errno | Same red indicator, tooltip "kill 失败 (errno: N)". | Manual retry. |
| Popover opens with empty records | Centered `ProgressView("扫描中...")`. | Automatic on scan completion. |
| Filtered records empty | Centered "无匹配的端口" text. | Adjust search. |
| Duplicate kill clicks on same pid | Kill icon disabled (row gray) while `killingPIDs` contains pid. | N/A. |

Logging: `os.Logger(subsystem: "dev.bybee.AnyDoor", category: "PortInventory")` records scan start/end/failure and kill calls (pid, signal, errno). Process names and command lines are not logged to avoid leaking user activity.

## Testing

### Package change

Add a test target to `Package.swift`:

```swift
.testTarget(
    name: "AnyDoorTests",
    dependencies: ["AnyDoor"],
    path: "Tests/AnyDoorTests",
    resources: [.process("Fixtures")]
)
```

### `PortScannerTests` (unit, no system dependency)

- `parseLsofOutput` fixtures:
  - single process, single IPv4 port
  - single process, multiple ports
  - same pid+port across IPv4/IPv6 → merged into one record with both families
  - long command name preserved (no truncation)
  - malformed input → throws `.parseFailed`
- `parseProcArgs` fixture: simulated KERN_PROCARGS2 byte buffer.

### `PortInventoryTests` (`@MainActor`, stub `PortScanning`)

- Search priority: records covering port `:3000`, process `node`, PID `67035`; query `"30"` returns the port-match first.
- Search is case-insensitive.
- `viewMode` round-trips through UserDefaults (isolated suite).
- Successful kill clears `killingPIDs` and refreshes records.
- `EPERM` populates `failedKillPIDs` with `.permissionDenied`.
- `ESRCH` does **not** populate `failedKillPIDs`.
- Consecutive `refresh()` calls cancel the previous task.
- `groupedByProcess` returns groups sorted by name with ports sorted ascending.

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
- `Sources/AnyDoor/Services/PortScanner.swift`
- `Sources/AnyDoor/Services/PortInventory.swift`
- `Sources/AnyDoor/Views/PortManagerPopoverView.swift`
- `Sources/AnyDoor/Views/PortListView.swift`
- `Sources/AnyDoor/Views/PortTreeView.swift`
- `Sources/AnyDoor/Views/PortRowView.swift` (shared row + status dot + kill icon)
- `Sources/AnyDoor/Views/PortProcessGroupView.swift`
- `Tests/AnyDoorTests/PortScannerTests.swift`
- `Tests/AnyDoorTests/PortInventoryTests.swift`
- `Tests/AnyDoorTests/Fixtures/lsof-*.txt` (fixture files)

**Modified**
- `Sources/AnyDoor/Models/BuiltinItem.swift` — add `.portManager` case with `.submenu` kind, title, symbol, default ordering.
- `Sources/AnyDoor/Models/HotkeyAction.swift` — add `.showSubmenu(BuiltinItem)` case and its `HotkeySnapshot` encoding.
- `Sources/AnyDoor/Services/PanelStore.swift` — add submenu open-request publisher; dispatch `.showSubmenu` accordingly.
- `Sources/AnyDoor/Views/MenuBarView.swift` — extend hover dispatch to mount `PortManagerPopoverView` for `.portManager`.
- `Package.swift` — add `.testTarget(name: "AnyDoorTests", ...)`.

No SwiftData schema changes (preference for `.portManager` is auto-seeded by the existing seeder).

## Open Questions

None. All clarifications captured above.

## Future Extensions (not in this design)

- Copy port / PID / command line to clipboard via context menu.
- Pin specific ports as favorites for quick access.
- Show CPU / memory next to each process.
- Background polling with delta animations.
- UDP / established connections via a view-mode segmented control.
- Keyboard navigation inside the list.
