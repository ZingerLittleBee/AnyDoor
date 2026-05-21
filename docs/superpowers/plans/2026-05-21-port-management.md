# Port Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a port management entry to the AnyDoor menu bar that, on hover, surfaces a popover listing all TCP listening ports with search, list/tree views, and pid-level kill.

**Architecture:** Three new isolated units. `PortScanner` (actor + `SubprocessRunning` protocol + `LsofRunner`) runs `lsof` with proper concurrent pipe drainage and exposes a stubbable interface; `parseLsofOutput` is a free function for fixture-driven tests. `PortInventory` (`@MainActor @Observable`) owns UI state — records, search, view mode, refresh generation token + inflight count, kill state machine. UI layer wires a new `PortManagerPopoverView` through the existing `HoverPopover` + `HoverGate` (with focus-friendly tweaks).

**Tech Stack:** Swift 6.2 (`.swiftLanguageMode(.v6)`), SwiftUI, SwiftData (no schema changes), `lsof`, `sysctl(KERN_PROCARGS2)`, `Darwin.kill(2)`, `OSAllocatedUnfairLock`, XCTest.

**Spec:** `docs/superpowers/specs/2026-05-21-port-management-design.md`.

---

## File Map

**Created:**
- `Sources/AnyDoor/Models/PortRecord.swift` — `PortRecord`, `PortBind`, `AddressFamily`, `SignalResult`, `ProcessGroup`.
- `Sources/AnyDoor/Services/PortScanner.swift` — `PortScanning`, `SubprocessRunning`, `SubprocessResult`, `LsofRunner`, `parseLsofOutput`, `parseProcArgs`, `PortScanner` actor.
- `Sources/AnyDoor/Services/PortInventory.swift` — `@MainActor @Observable final class PortInventory`, `ViewMode`, `KillFailure`, `PortInventoryError`.
- `Sources/AnyDoor/Views/PortManagerPopoverView.swift` — popover root + `KeyboardMonitor` + header/toolbar/banner subviews.
- `Sources/AnyDoor/Views/PortListView.swift` — list mode + `PortRowView` + `PortStatusDot`.
- `Sources/AnyDoor/Views/PortTreeView.swift` — tree mode with `DisclosureGroup` + bind summary helper.
- `Tests/AnyDoorTests/PortScannerTests.swift`
- `Tests/AnyDoorTests/PortInventoryTests.swift`
- `Tests/AnyDoorTests/Fixtures/lsof-single-ipv4.txt`
- `Tests/AnyDoorTests/Fixtures/lsof-multi-port.txt`
- `Tests/AnyDoorTests/Fixtures/lsof-dual-stack.txt`
- `Tests/AnyDoorTests/Fixtures/lsof-multi-bind.txt`
- `Tests/AnyDoorTests/Fixtures/lsof-ipv6-zone.txt`
- `Tests/AnyDoorTests/Fixtures/lsof-command-spaces.txt`
- `Tests/AnyDoorTests/Fixtures/lsof-escape.txt`

**Modified:**
- `Sources/AnyDoor/Models/BuiltinItem.swift` — add `.portManager` case to enum + each switch + defaultOrder.
- `Sources/AnyDoor/Views/HoverPopover.swift` — opt-in key-focus via `NSPanel(.nonactivatingPanel)`, `isHoldingFocus` observable.
- `Sources/AnyDoor/Views/MenuBarView.swift` — generalise per-submenu trigger frames, dispatch `.portManager`, guard `onDisappear`.
- `Sources/AnyDoor/Views/PanelSettingsView.swift` — generalise submenu hotkey-recorder filter.
- `Package.swift` — bundle `Tests/AnyDoorTests/Fixtures/` as test resources.

---

## Task 1: Add `.portManager` to `BuiltinItem`

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift`
- Test: `Tests/AnyDoorTests/PortInventoryTests.swift` (new file with one regression test)

- [ ] **Step 1: Write the failing regression test**

Create `Tests/AnyDoorTests/PortInventoryTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class PortInventoryTests: XCTestCase {
    func testBuiltinItemPortManagerExists() {
        XCTAssertTrue(BuiltinItem.allCases.contains(.portManager))
        XCTAssertEqual(BuiltinItem.portManager.kind, .submenu)
        XCTAssertEqual(BuiltinItem.portManager.title, "端口管理")
        XCTAssertEqual(BuiltinItem.portManager.symbol, "network")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter PortInventoryTests/testBuiltinItemPortManagerExists`
Expected: build error — `portManager` is not a case of `BuiltinItem`.

- [ ] **Step 3: Add the enum case + every switch arm**

Edit `Sources/AnyDoor/Models/BuiltinItem.swift`:

Add `case portManager` after `case keyboardLock`:

```swift
    case keyboardLock
    case portManager
```

Extend `kind`:

```swift
        case .appShortcuts, .portManager: return .submenu
```
(replace the existing `case .appShortcuts: return .submenu` line.)

Extend `title`:

```swift
        case .portManager: return "端口管理"
```
(add to the `title` switch.)

Extend `symbol`:

```swift
        case .portManager: return "network"
```
(add to the `symbol` switch. Note: this collides with `.flushDNS` which currently uses `"network"` — leave `.flushDNS` alone; SF Symbols allow duplicates.)

Extend `defaultOrder` (place at the tail):

```swift
        case .portManager: return 1900
```

`requiresAutomation` and `feedbackSound` keep their `default` fallback — no change needed.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter PortInventoryTests/testBuiltinItemPortManagerExists`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift Tests/AnyDoorTests/PortInventoryTests.swift
git commit -m "feat(builtin): add portManager submenu case"
```

---

## Task 2: Define domain types in `Models/PortRecord.swift`

**Files:**
- Create: `Sources/AnyDoor/Models/PortRecord.swift`
- Test: extend `Tests/AnyDoorTests/PortInventoryTests.swift`

- [ ] **Step 1: Add failing test for domain types**

Append to `Tests/AnyDoorTests/PortInventoryTests.swift`:

```swift
    func testPortRecordIdComposition() {
        let r = PortRecord(
            port: 3000,
            pid: 67035,
            processName: "node",
            executablePath: nil,
            commandLine: nil,
            binds: [PortBind(address: "*", family: .ipv4)]
        )
        XCTAssertEqual(r.id, "67035-3000")
    }

    func testSignalResultEquatable() {
        XCTAssertEqual(SignalResult.success, SignalResult.success)
        XCTAssertEqual(SignalResult.failure(.EPERM), SignalResult.failure(.EPERM))
        XCTAssertNotEqual(SignalResult.success, SignalResult.failure(.EPERM))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PortInventoryTests`
Expected: build error — `PortRecord`, `PortBind`, `SignalResult` undefined.

- [ ] **Step 3: Create the domain model file**

Create `Sources/AnyDoor/Models/PortRecord.swift`:

```swift
import Foundation
import Darwin

/// Listening TCP port discovered on the local machine. Identity is `(pid, port)`.
struct PortRecord: Sendable, Hashable, Identifiable {
    let port: UInt16
    let pid: pid_t
    let processName: String
    let executablePath: String?
    let commandLine: String?
    /// Every distinct bind seen for this (pid, port). Never empty; ordered IPv4 first then IPv6.
    let binds: [PortBind]
    var id: String { "\(pid)-\(port)" }
}

struct PortBind: Sendable, Hashable {
    let address: String          // "*", "127.0.0.1", "::1", "fe80::1%en0", ...
    let family: AddressFamily
}

enum AddressFamily: String, Sendable, Hashable, CaseIterable {
    case ipv4 = "IPv4"
    case ipv6 = "IPv6"
}

/// Outcome of a `Darwin.kill(2)` syscall. `errno` is captured immediately into
/// the failure case to avoid clobbering by subsequent system calls.
enum SignalResult: Sendable, Equatable {
    case success
    case failure(POSIXErrorCode)
}

/// View-model grouping of records belonging to a single process. Used by the tree view.
struct ProcessGroup: Sendable, Identifiable {
    var id: pid_t { pid }
    let pid: pid_t
    let processName: String
    let ports: [PortRecord]      // sorted by port ascending
}
```

- [ ] **Step 4: Run to verify passes**

Run: `swift test --filter PortInventoryTests`
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/PortRecord.swift Tests/AnyDoorTests/PortInventoryTests.swift
git commit -m "feat(model): add PortRecord/PortBind/SignalResult domain types"
```

---

## Task 3: Wire test fixture resources in `Package.swift`

**Files:**
- Modify: `Package.swift`
- Create: `Tests/AnyDoorTests/Fixtures/.gitkeep`

- [ ] **Step 1: Confirm current Package.swift**

Read `/Users/zingerbee/Bee/AnyDoor/Package.swift`. It currently has:
```swift
.testTarget(
    name: "AnyDoorTests",
    dependencies: ["AnyDoor"],
    swiftSettings: [
        .swiftLanguageMode(.v6),
    ]
),
```

- [ ] **Step 2: Add `resources:` to the existing test target**

Edit `Package.swift`. Replace the test target with:

```swift
        .testTarget(
            name: "AnyDoorTests",
            dependencies: ["AnyDoor"],
            resources: [.process("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
```

- [ ] **Step 3: Create the Fixtures directory placeholder**

Create empty file `Tests/AnyDoorTests/Fixtures/.gitkeep` so the empty directory exists for SwiftPM resource processing.

```bash
mkdir -p Tests/AnyDoorTests/Fixtures
touch Tests/AnyDoorTests/Fixtures/.gitkeep
```

- [ ] **Step 4: Verify build still succeeds**

Run: `swift build`
Expected: clean build, no warnings about missing resources.

Run: `swift test --filter SmokeTest`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Tests/AnyDoorTests/Fixtures/.gitkeep
git commit -m "build(tests): enable fixture resources for AnyDoorTests"
```

---

## Task 4: Skeleton `PortScanner.swift` with types

**Files:**
- Create: `Sources/AnyDoor/Services/PortScanner.swift`
- Test: extend `Tests/AnyDoorTests/PortInventoryTests.swift` with a compile-only check.

- [ ] **Step 1: Add failing test**

Append to `Tests/AnyDoorTests/PortInventoryTests.swift`:

```swift
    func testSubprocessResultStruct() {
        let r = SubprocessResult(
            stdout: "out", stderr: "err", exit: 0, timedOut: false
        )
        XCTAssertEqual(r.stdout, "out")
        XCTAssertEqual(r.stderr, "err")
        XCTAssertEqual(r.exit, 0)
        XCTAssertFalse(r.timedOut)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PortInventoryTests/testSubprocessResultStruct`
Expected: build error — `SubprocessResult` undefined.

- [ ] **Step 3: Create the scanner skeleton**

Create `Sources/AnyDoor/Services/PortScanner.swift`:

```swift
import Foundation
import Darwin
import os

// MARK: - Subprocess runner protocol

protocol SubprocessRunning: Sendable {
    func run(
        path: String,
        args: [String],
        timeout: Duration
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

// MARK: - Scanner protocol

protocol PortScanning: Sendable {
    func scanTCPListening() async throws -> [PortRecord]
    func kill(pid: pid_t, signal: Int32) -> SignalResult
}

enum PortScanError: Error, Equatable {
    case lsofTimeout
    case lsofFailed(exitCode: Int32, stderr: String)
    case parseFailed(line: String)
}

// MARK: - PortScanner actor (skeleton — implemented across later tasks)

actor PortScanner: PortScanning {
    private let runner: any SubprocessRunning
    private static let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "PortScanner")

    init(runner: any SubprocessRunning = LsofRunner()) {
        self.runner = runner
    }

    func scanTCPListening() async throws -> [PortRecord] {
        // Implemented in Task 7.
        return []
    }

    nonisolated func kill(pid: pid_t, signal: Int32) -> SignalResult {
        if Darwin.kill(pid, signal) == 0 { return .success }
        let code = POSIXErrorCode(rawValue: errno) ?? .EINVAL
        return .failure(code)
    }
}

// MARK: - LsofRunner placeholder (real implementation lands in Task 8)

struct LsofRunner: SubprocessRunning {
    func run(path: String, args: [String], timeout: Duration) async throws -> SubprocessResult {
        // Placeholder; replaced in Task 8.
        return SubprocessResult(stdout: "", stderr: "", exit: 0, timedOut: false)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build`
Expected: clean build.

Run: `swift test --filter PortInventoryTests/testSubprocessResultStruct`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/PortScanner.swift Tests/AnyDoorTests/PortInventoryTests.swift
git commit -m "feat(scanner): add PortScanner skeleton with protocol surface"
```

---

## Task 5: Implement `parseLsofOutput` — single IPv4 listener

**Files:**
- Modify: `Sources/AnyDoor/Services/PortScanner.swift`
- Create: `Tests/AnyDoorTests/Fixtures/lsof-single-ipv4.txt`
- Create: `Tests/AnyDoorTests/PortScannerTests.swift`

- [ ] **Step 1: Add the fixture**

Create `Tests/AnyDoorTests/Fixtures/lsof-single-ipv4.txt` with these exact bytes (no trailing whitespace except final newline):

```
p67035
cnode
LZinger
f17
PTCP
tIPv4
n*:3000
```

This is real `lsof -F pPcntL` output: one process record (`p` introduces, `c L` are process fields), then one file record (`f` introduces, `P t n` are file fields).

- [ ] **Step 2: Write the failing test**

Create `Tests/AnyDoorTests/PortScannerTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class PortScannerTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "txt") else {
            XCTFail("fixture \(name).txt not found in test bundle")
            throw XCTSkip("missing fixture")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParseSingleIPv4Listener() throws {
        let raw = try fixture("lsof-single-ipv4")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.pid, 67035)
        XCTAssertEqual(r.port, 3000)
        XCTAssertEqual(r.processName, "node")
        XCTAssertEqual(r.binds, [PortBind(address: "*", family: .ipv4)])
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --filter PortScannerTests/testParseSingleIPv4Listener`
Expected: build error — `parseLsofOutput` undefined.

- [ ] **Step 4: Implement `parseLsofOutput`**

Append to `Sources/AnyDoor/Services/PortScanner.swift`:

```swift
// MARK: - lsof -F output parser

/// Parses the output of `lsof -nP -iTCP -sTCP:LISTEN -F pPcntL +c 0`.
///
/// Field format reference (from `lsof -F?`):
///   p = process id, c = command name, L = login name (process records)
///   f = file descriptor (starts a new file record), P = protocol, t = file type
///   (IPv4/IPv6), n = comment/name ("addr:port")
///
/// Each line is `<fieldChar><value>`. `p` starts a new process group; `f` starts
/// a new file within the current process group.
func parseLsofOutput(_ raw: String) throws -> [PortRecord] {
    struct PartialFile {
        var family: AddressFamily?
        var name: String?
        var protocolName: String?
    }
    struct PartialProcess {
        var pid: pid_t?
        var command: String = ""
        var files: [PartialFile] = []
    }

    var partials: [PartialProcess] = []
    var currentProcess: PartialProcess? = nil
    var currentFile: PartialFile? = nil

    func flushFile() {
        if let file = currentFile, currentProcess != nil {
            currentProcess!.files.append(file)
        }
        currentFile = nil
    }
    func flushProcess() {
        flushFile()
        if let proc = currentProcess { partials.append(proc) }
        currentProcess = nil
    }

    for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let first = rawLine.first else { continue }
        let value = String(rawLine.dropFirst())

        switch first {
        case "p":
            flushProcess()
            currentProcess = PartialProcess(pid: pid_t(value), command: "", files: [])
        case "c":
            if currentProcess != nil { currentProcess!.command = decodeLsofEscapes(value) }
        case "L":
            break // login name unused
        case "f":
            flushFile()
            currentFile = PartialFile()
        case "P":
            if currentFile != nil { currentFile!.protocolName = value }
        case "t":
            if currentFile != nil { currentFile!.family = AddressFamily(rawValue: value) }
        case "n":
            if currentFile != nil { currentFile!.name = value }
        default:
            break // unknown field — ignore for forward-compat
        }
    }
    flushProcess()

    // Group by (pid, port). Within a group, accumulate distinct binds.
    struct Key: Hashable { let pid: pid_t; let port: UInt16 }
    var groups: [Key: (processName: String, binds: [PortBind])] = [:]
    var keyOrder: [Key] = []

    for proc in partials {
        guard let pid = proc.pid else { continue }
        for file in proc.files {
            guard let name = file.name,
                  let (address, port) = parseAddressPort(name),
                  let family = file.family else { continue }
            let key = Key(pid: pid, port: port)
            let bind = PortBind(address: address, family: family)
            if var existing = groups[key] {
                if !existing.binds.contains(bind) { existing.binds.append(bind) }
                groups[key] = existing
            } else {
                groups[key] = (proc.command, [bind])
                keyOrder.append(key)
            }
        }
    }

    return keyOrder.map { key in
        let g = groups[key]!
        let sortedBinds = g.binds.sorted { $0.family.rawValue < $1.family.rawValue }
        return PortRecord(
            port: key.port,
            pid: key.pid,
            processName: g.processName,
            executablePath: nil,
            commandLine: nil,
            binds: sortedBinds
        )
    }
}

/// Parses the `n` field's `addr:port` value. Handles three forms:
///   `*:3000`, `127.0.0.1:5000`, `[::1]:8080`, `[fe80::1%en0]:1234`.
private func parseAddressPort(_ raw: String) -> (address: String, port: UInt16)? {
    // IPv6 bracketed form
    if raw.hasPrefix("[") {
        guard let close = raw.firstIndex(of: "]") else { return nil }
        let address = String(raw[raw.index(after: raw.startIndex)..<close])
        let after = raw.index(after: close)
        guard after < raw.endIndex, raw[after] == ":" else { return nil }
        let portStr = raw[raw.index(after: after)...]
        guard let port = UInt16(portStr) else { return nil }
        return (address, port)
    }
    // Plain "address:port"
    guard let lastColon = raw.lastIndex(of: ":") else { return nil }
    let address = String(raw[raw.startIndex..<lastColon])
    let portStr = raw[raw.index(after: lastColon)...]
    guard let port = UInt16(portStr) else { return nil }
    return (address, port)
}

/// lsof escapes non-printable bytes in command names as `\xHH`. Decode them back
/// to UTF-8 bytes when possible. Spaces and printable ASCII pass through.
private func decodeLsofEscapes(_ raw: String) -> String {
    guard raw.contains("\\x") else { return raw }
    var bytes: [UInt8] = []
    let scalars = Array(raw.unicodeScalars)
    var i = 0
    while i < scalars.count {
        if scalars[i] == "\\", i + 3 < scalars.count, scalars[i + 1] == "x",
           let hi = hexNibble(scalars[i + 2]), let lo = hexNibble(scalars[i + 3]) {
            bytes.append(UInt8(hi << 4 | lo))
            i += 4
        } else {
            // Append the scalar's UTF-8 bytes
            for byte in String(scalars[i]).utf8 { bytes.append(byte) }
            i += 1
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func hexNibble(_ s: Unicode.Scalar) -> UInt8? {
    switch s {
    case "0"..."9": return UInt8(s.value - Unicode.Scalar("0").value)
    case "a"..."f": return UInt8(s.value - Unicode.Scalar("a").value + 10)
    case "A"..."F": return UInt8(s.value - Unicode.Scalar("A").value + 10)
    default: return nil
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter PortScannerTests/testParseSingleIPv4Listener`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Services/PortScanner.swift Tests/AnyDoorTests/PortScannerTests.swift Tests/AnyDoorTests/Fixtures/lsof-single-ipv4.txt
git commit -m "feat(scanner): parse lsof -F output for single IPv4 listener"
```

---

## Task 6: Extend parser — multi-port, dual-stack, multi-bind, IPv6 zone, command spaces, escape

**Files:**
- Create: 6 fixture files under `Tests/AnyDoorTests/Fixtures/`
- Modify: `Tests/AnyDoorTests/PortScannerTests.swift`

- [ ] **Step 1: Add the multi-port fixture**

Create `Tests/AnyDoorTests/Fixtures/lsof-multi-port.txt`:

```
p898
cOrbStack Helper
LZinger
f17
PTCP
tIPv4
n*:80
f18
PTCP
tIPv4
n*:443
f19
PTCP
tIPv4
n*:5432
```

- [ ] **Step 2: Add the dual-stack fixture**

Create `Tests/AnyDoorTests/Fixtures/lsof-dual-stack.txt`:

```
p75837
cControlCenter
LZinger
f17
PTCP
tIPv4
n*:5000
f18
PTCP
tIPv6
n*:5000
```

- [ ] **Step 3: Add the multi-bind fixture**

Create `Tests/AnyDoorTests/Fixtures/lsof-multi-bind.txt`:

```
p4242
cmyserver
LZinger
f10
PTCP
tIPv4
n127.0.0.1:5000
f11
PTCP
tIPv4
n0.0.0.0:5000
```

- [ ] **Step 4: Add the IPv6 zone fixture**

Create `Tests/AnyDoorTests/Fixtures/lsof-ipv6-zone.txt`:

```
p999
clinkservice
LZinger
f7
PTCP
tIPv6
n[fe80::1%en0]:1234
```

- [ ] **Step 5: Add the command-name-with-spaces fixture**

Create `Tests/AnyDoorTests/Fixtures/lsof-command-spaces.txt`:

```
p1234
cGoogle Chrome Helper
LZinger
f99
PTCP
tIPv4
n*:9222
```

- [ ] **Step 6: Add the escape-sequence fixture**

Create `Tests/AnyDoorTests/Fixtures/lsof-escape.txt`:

```
p5555
cweird\x20name
LZinger
f1
PTCP
tIPv4
n*:7777
```

(After decoding `\x20`, the command name should become `weird name`.)

- [ ] **Step 7: Add the tests**

Append to `Tests/AnyDoorTests/PortScannerTests.swift` (inside the same class):

```swift
    func testParseMultiPort() throws {
        let raw = try fixture("lsof-multi-port")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.port), [80, 443, 5432])
        for r in records { XCTAssertEqual(r.pid, 898); XCTAssertEqual(r.processName, "OrbStack Helper") }
    }

    func testParseDualStackMergesBinds() throws {
        let raw = try fixture("lsof-dual-stack")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.pid, 75837)
        XCTAssertEqual(r.port, 5000)
        XCTAssertEqual(r.binds.count, 2)
        XCTAssertEqual(Set(r.binds.map(\.family)), Set([.ipv4, .ipv6]))
        // Ordering: IPv4 first then IPv6 (sorted by rawValue).
        XCTAssertEqual(r.binds.map(\.family), [.ipv4, .ipv6])
    }

    func testParseMultiBindSamePort() throws {
        let raw = try fixture("lsof-multi-bind")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.binds.count, 2)
        XCTAssertEqual(Set(r.binds.map(\.address)), Set(["127.0.0.1", "0.0.0.0"]))
    }

    func testParseIPv6ZoneId() throws {
        let raw = try fixture("lsof-ipv6-zone")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.port, 1234)
        XCTAssertEqual(r.binds, [PortBind(address: "fe80::1%en0", family: .ipv6)])
    }

    func testParseCommandWithSpaces() throws {
        let raw = try fixture("lsof-command-spaces")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].processName, "Google Chrome Helper")
    }

    func testParseEscapeSequence() throws {
        let raw = try fixture("lsof-escape")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].processName, "weird name")
    }
```

- [ ] **Step 8: Run all parser tests**

Run: `swift test --filter PortScannerTests`
Expected: all 7 tests pass (the original `testParseSingleIPv4Listener` + 6 new).

If any fails, the parser needs adjustment — re-read the failing test's expectations and fix in `parseLsofOutput` / `parseAddressPort` / `decodeLsofEscapes`.

- [ ] **Step 9: Commit**

```bash
git add Tests/AnyDoorTests/Fixtures/lsof-multi-port.txt Tests/AnyDoorTests/Fixtures/lsof-dual-stack.txt Tests/AnyDoorTests/Fixtures/lsof-multi-bind.txt Tests/AnyDoorTests/Fixtures/lsof-ipv6-zone.txt Tests/AnyDoorTests/Fixtures/lsof-command-spaces.txt Tests/AnyDoorTests/Fixtures/lsof-escape.txt Tests/AnyDoorTests/PortScannerTests.swift
git commit -m "test(scanner): cover multi-port, dual-stack, multi-bind, IPv6 zone, escapes"
```

---

## Task 7: Implement `scanTCPListening` with stub runner + empty-result / timeout / failure rules

**Files:**
- Modify: `Sources/AnyDoor/Services/PortScanner.swift`
- Modify: `Tests/AnyDoorTests/PortScannerTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnyDoorTests/PortScannerTests.swift`:

```swift
    // Stub runner used to exercise scanner branches without spawning lsof.
    private struct StubRunner: SubprocessRunning {
        let result: SubprocessResult
        func run(path: String, args: [String], timeout: Duration) async throws -> SubprocessResult {
            result
        }
    }

    func testScanEmptyResultExit1BothStreamsEmpty() async throws {
        let scanner = PortScanner(runner: StubRunner(
            result: SubprocessResult(stdout: "", stderr: "", exit: 1, timedOut: false)
        ))
        let records = try await scanner.scanTCPListening()
        XCTAssertEqual(records, [])
    }

    func testScanExit1WithStderrIsFailure() async {
        let scanner = PortScanner(runner: StubRunner(
            result: SubprocessResult(stdout: "", stderr: "lsof: permission denied\n", exit: 1, timedOut: false)
        ))
        do {
            _ = try await scanner.scanTCPListening()
            XCTFail("expected lsofFailed")
        } catch let PortScanError.lsofFailed(code, stderr) {
            XCTAssertEqual(code, 1)
            XCTAssertTrue(stderr.contains("permission denied"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testScanTimeoutThrowsRegardlessOfExit() async {
        let scanner = PortScanner(runner: StubRunner(
            result: SubprocessResult(stdout: "anything", stderr: "", exit: 0, timedOut: true)
        ))
        do {
            _ = try await scanner.scanTCPListening()
            XCTFail("expected lsofTimeout")
        } catch PortScanError.lsofTimeout {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testScanSuccessfulParse() async throws {
        let raw = try fixture("lsof-single-ipv4")
        let scanner = PortScanner(runner: StubRunner(
            result: SubprocessResult(stdout: raw, stderr: "", exit: 0, timedOut: false)
        ))
        let records = try await scanner.scanTCPListening()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].port, 3000)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PortScannerTests/testScanEmptyResultExit1BothStreamsEmpty`
Expected: fails because `scanTCPListening` returns `[]` for everything.

- [ ] **Step 3: Implement scan branching**

Replace the body of `scanTCPListening()` in `Sources/AnyDoor/Services/PortScanner.swift`:

```swift
    func scanTCPListening() async throws -> [PortRecord] {
        let result = try await runner.run(
            path: "/usr/sbin/lsof",
            args: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pPcntL", "+c", "0"],
            timeout: .seconds(3)
        )

        if result.timedOut { throw PortScanError.lsofTimeout }

        // lsof returns exit 1 with empty stdout AND empty stderr when there is
        // no matching open file. Treat that as a successful empty scan.
        if result.exit == 1 && result.stdout.isEmpty && result.stderr.isEmpty {
            return []
        }
        // Non-zero exit with any output on stderr (or stdout) is a real failure.
        if result.exit != 0 {
            throw PortScanError.lsofFailed(exitCode: result.exit, stderr: result.stderr)
        }

        var records = try parseLsofOutput(result.stdout)
        records = enrichWithProcArgs(records)
        return records
    }

    /// Enriches each record's `executablePath` and `commandLine` via sysctl.
    /// One sysctl call per unique pid; failures are silent (record keeps lsof's data).
    private func enrichWithProcArgs(_ records: [PortRecord]) -> [PortRecord] {
        var cache: [pid_t: (path: String?, command: String?)] = [:]
        return records.map { r in
            if cache[r.pid] == nil {
                cache[r.pid] = parseProcArgs(forPid: r.pid)
            }
            let info = cache[r.pid] ?? (nil, nil)
            return PortRecord(
                port: r.port,
                pid: r.pid,
                processName: r.processName,
                executablePath: info.path,
                commandLine: info.command,
                binds: r.binds
            )
        }
    }
```

Also add a placeholder `parseProcArgs` helper that returns `(nil, nil)` for now (it gets fleshed out in Task 8). Append:

```swift
// MARK: - sysctl KERN_PROCARGS2 helper (filled in Task 8)

func parseProcArgs(forPid pid: pid_t) -> (path: String?, command: String?) {
    // Task 8 replaces this stub with the real sysctl-based implementation.
    return (nil, nil)
}
```

- [ ] **Step 4: Run all scanner tests**

Run: `swift test --filter PortScannerTests`
Expected: all 11 tests pass (7 parser + 4 scanner-branch tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/PortScanner.swift Tests/AnyDoorTests/PortScannerTests.swift
git commit -m "feat(scanner): scanTCPListening with timeout/empty/failure branches"
```

---

## Task 8: Replace `LsofRunner` and `parseProcArgs` with real implementations

**Files:**
- Modify: `Sources/AnyDoor/Services/PortScanner.swift`

- [ ] **Step 1: Replace the `LsofRunner` placeholder**

In `Sources/AnyDoor/Services/PortScanner.swift`, replace the placeholder `LsofRunner` struct with:

```swift
struct LsofRunner: SubprocessRunning {
    func run(path: String, args: [String], timeout: Duration) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() }
        catch { throw SubprocessError.spawnFailed("\(error)") }

        // OSAllocatedUnfairLock<Bool> — no new dependency, watchdog and
        // result-builder both read/write through .withLock.
        let timedOut = OSAllocatedUnfairLock<Bool>(initialState: false)

        return await withTaskCancellationHandler {
            // Drain pipes concurrently so the kernel buffer never fills.
            async let outData: Data = readAll(outPipe.fileHandleForReading)
            async let errData: Data = readAll(errPipe.fileHandleForReading)

            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                if process.isRunning {
                    timedOut.withLock { $0 = true }
                    process.terminate()
                }
            }

            let out = await outData
            let err = await errData
            watchdog.cancel()
            process.waitUntilExit()

            return SubprocessResult(
                stdout: String(data: out, encoding: .utf8) ?? "",
                stderr: String(data: err, encoding: .utf8) ?? "",
                exit: process.terminationStatus,
                timedOut: timedOut.withLock { $0 }
            )
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private func readAll(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
        DispatchQueue.global().async {
            let data = (try? handle.readToEnd()) ?? Data()
            cont.resume(returning: data)
        }
    }
}
```

Add `import os` at the top of the file if missing (the existing import line is already `import os`; verify).

- [ ] **Step 2: Replace the `parseProcArgs` stub**

In the same file, replace the `parseProcArgs` placeholder with:

```swift
/// Reads `KERN_PROCARGS2` for a pid and extracts the executable path and the
/// space-joined argv. Returns `(nil, nil)` on any failure (permission, race,
/// pid no longer alive). Silent by design — caller falls back to lsof's command.
func parseProcArgs(forPid pid: pid_t) -> (path: String?, command: String?) {
    var size: Int = 0
    var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    // First call: ask for size.
    if sysctl(&name, 3, nil, &size, nil, 0) != 0 || size == 0 {
        return (nil, nil)
    }
    var buffer = [UInt8](repeating: 0, count: size)
    if sysctl(&name, 3, &buffer, &size, nil, 0) != 0 {
        return (nil, nil)
    }

    // Layout: <argc:Int32><executable path NUL>[padding NULs]<argv[0] NUL><argv[1] NUL>...
    guard size >= MemoryLayout<Int32>.size else { return (nil, nil) }
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    if argc < 0 { return (nil, nil) }

    var cursor = MemoryLayout<Int32>.size
    // Read NUL-terminated executable path.
    let pathStart = cursor
    while cursor < buffer.count && buffer[cursor] != 0 { cursor += 1 }
    let pathBytes = buffer[pathStart..<cursor]
    let path = String(decoding: pathBytes, as: UTF8.self)
    // Skip padding NULs.
    while cursor < buffer.count && buffer[cursor] == 0 { cursor += 1 }

    // Read argc NUL-terminated argv entries.
    var argv: [String] = []
    var collected = 0
    while collected < Int(argc) && cursor < buffer.count {
        let start = cursor
        while cursor < buffer.count && buffer[cursor] != 0 { cursor += 1 }
        argv.append(String(decoding: buffer[start..<cursor], as: UTF8.self))
        if cursor < buffer.count { cursor += 1 } // skip NUL
        collected += 1
    }
    let command = argv.joined(separator: " ")
    return (path.isEmpty ? nil : path, command.isEmpty ? nil : command)
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Run all existing tests (regression check)**

Run: `swift test --filter PortScannerTests`
Expected: all 11 still pass (the real runner is not exercised; tests still inject `StubRunner`).

- [ ] **Step 5: Dev-only smoke test (manual)**

Open a terminal in this repo and run a one-off Swift snippet (do NOT add to CI):

```bash
cat > /tmp/scan-smoke.swift <<'SWIFT'
@testable import AnyDoor
import Foundation
Task {
    let s = PortScanner()
    do {
        let records = try await s.scanTCPListening()
        print("found \(records.count) listeners")
        for r in records.prefix(5) { print(":\(r.port) \(r.processName) (pid \(r.pid))") }
    } catch { print("error: \(error)") }
    exit(0)
}
RunLoop.main.run()
SWIFT
echo "(snippet at /tmp/scan-smoke.swift — manual run is optional)"
```

This is a documentation step only. The next agent doesn't need to execute it.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Services/PortScanner.swift
git commit -m "feat(scanner): real LsofRunner with concurrent drain + KERN_PROCARGS2"
```

---

## Task 9: Skeleton `PortInventory` with viewMode persistence

**Files:**
- Create: `Sources/AnyDoor/Services/PortInventory.swift`
- Modify: `Tests/AnyDoorTests/PortInventoryTests.swift`

- [ ] **Step 1: Add the failing tests**

Append to `Tests/AnyDoorTests/PortInventoryTests.swift`:

```swift
    @MainActor
    func testViewModeDefaultsToList() {
        let defaults = isolatedDefaults()
        let inventory = PortInventory(
            scanner: StubScanner(records: []),
            defaults: defaults
        )
        XCTAssertEqual(inventory.viewMode, .list)
    }

    @MainActor
    func testViewModePersistsToDefaults() {
        let defaults = isolatedDefaults()
        let inventory = PortInventory(
            scanner: StubScanner(records: []),
            defaults: defaults
        )
        inventory.viewMode = .tree

        // New instance reads back the persisted value.
        let inventory2 = PortInventory(
            scanner: StubScanner(records: []),
            defaults: defaults
        )
        XCTAssertEqual(inventory2.viewMode, .tree)
    }

    // Test helpers
    private struct StubScanner: PortScanning {
        let records: [PortRecord]
        var killBehavior: @Sendable (pid_t, Int32) -> SignalResult = { _, _ in .success }
        func scanTCPListening() async throws -> [PortRecord] { records }
        func kill(pid: pid_t, signal: Int32) -> SignalResult { killBehavior(pid, signal) }
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "PortInventoryTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PortInventoryTests/testViewModeDefaultsToList`
Expected: build error — `PortInventory` undefined.

- [ ] **Step 3: Create the inventory file**

Create `Sources/AnyDoor/Services/PortInventory.swift`:

```swift
import Foundation
import Darwin
import os

@MainActor
@Observable
final class PortInventory {
    // MARK: - Public state

    private(set) var records: [PortRecord] = []
    private(set) var isRefreshing: Bool = false
    private(set) var lastError: PortInventoryError? = nil
    private(set) var killingPIDs: Set<pid_t> = []
    private(set) var failedKillPIDs: [pid_t: KillFailure] = [:]

    var searchText: String = ""

    var viewMode: ViewMode {
        didSet {
            defaults.set(viewMode.rawValue, forKey: Self.viewModeKey)
        }
    }

    // MARK: - Dependencies

    private let scanner: any PortScanning
    private let defaults: UserDefaults
    private static let viewModeKey = "PortInventory.viewMode"
    private static let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "PortInventory")

    // MARK: - Internal refresh state (Task 10)

    private var refreshGeneration: UInt64 = 0
    private var inflightCount: Int = 0

    // MARK: - Lifecycle

    nonisolated static let shared = PortInventory()

    init(
        scanner: any PortScanning = PortScanner(),
        defaults: UserDefaults = .standard
    ) {
        self.scanner = scanner
        self.defaults = defaults
        let raw = defaults.string(forKey: Self.viewModeKey)
        self.viewMode = raw.flatMap(ViewMode.init(rawValue:)) ?? .list
    }

    // Placeholder methods — real implementations land in Task 10 and Task 11.

    func refresh() async {
        // Implemented in Task 10.
    }

    func kill(pid: pid_t) async {
        // Implemented in Task 11.
    }

    func dismissError(for pid: pid_t) {
        failedKillPIDs.removeValue(forKey: pid)
    }
}

enum ViewMode: String, Sendable, Equatable {
    case list, tree
}

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

Note: `nonisolated static let shared = PortInventory()` requires that `PortInventory.init` is callable from a nonisolated context. Since the class is `@MainActor`, the no-arg init needs to be marked accordingly. Adjust if Swift rejects: change to `static let shared: PortInventory = MainActor.assumeIsolated { PortInventory() }`.

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter PortInventoryTests`
Expected: at minimum the two viewMode tests pass alongside earlier ones.

If `shared` causes a Swift 6 actor-isolation error, switch to:

```swift
static let shared: PortInventory = MainActor.assumeIsolated { PortInventory() }
```

Re-run.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/PortInventory.swift Tests/AnyDoorTests/PortInventoryTests.swift
git commit -m "feat(inventory): PortInventory skeleton with viewMode persistence"
```

---

## Task 10: Implement `refresh()` with generation token + inflightCount

**Files:**
- Modify: `Sources/AnyDoor/Services/PortInventory.swift`
- Modify: `Tests/AnyDoorTests/PortInventoryTests.swift`

- [ ] **Step 1: Add the failing tests**

Append to `Tests/AnyDoorTests/PortInventoryTests.swift`. First, a controllable async scanner:

```swift
    /// Scanner that lets the test resolve `scanTCPListening()` on demand.
    private actor BlockingScanner: PortScanning {
        struct Pending {
            let continuation: CheckedContinuation<[PortRecord], Error>
        }
        private var queue: [Pending] = []
        private(set) var calls = 0
        func resolve(with records: [PortRecord]) async {
            calls += 1
            if let next = queue.first {
                queue.removeFirst()
                next.continuation.resume(returning: records)
            }
        }
        func fail(with error: Error) async {
            if let next = queue.first {
                queue.removeFirst()
                next.continuation.resume(throwing: error)
            }
        }
        func scanTCPListening() async throws -> [PortRecord] {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[PortRecord], Error>) in
                queue.append(Pending(continuation: cont))
            }
        }
        nonisolated func kill(pid: pid_t, signal: Int32) -> SignalResult { .success }
    }

    @MainActor
    func testRefreshPopulatesRecords() async {
        let stub = StubScanner(records: [
            PortRecord(port: 3000, pid: 1, processName: "node",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)])
        ])
        let inv = PortInventory(scanner: stub, defaults: isolatedDefaults())
        await inv.refresh()
        XCTAssertEqual(inv.records.count, 1)
        XCTAssertEqual(inv.records[0].port, 3000)
        XCTAssertFalse(inv.isRefreshing)
        XCTAssertNil(inv.lastError)
    }

    @MainActor
    func testRefreshFailurePreservesRecordsAndSetsError() async {
        struct ThrowingScanner: PortScanning {
            func scanTCPListening() async throws -> [PortRecord] {
                throw PortScanError.lsofFailed(exitCode: 2, stderr: "boom")
            }
            func kill(pid: pid_t, signal: Int32) -> SignalResult { .success }
        }
        let inv = PortInventory(scanner: ThrowingScanner(), defaults: isolatedDefaults())
        // Seed records via a stub first refresh would be ideal; here we just verify error path.
        await inv.refresh()
        XCTAssertNotNil(inv.lastError)
        XCTAssertFalse(inv.isRefreshing)
    }

    @MainActor
    func testIsRefreshingClearsOnlyWhenAllInflightFinish() async throws {
        let scanner = BlockingScanner()
        let inv = PortInventory(scanner: scanner, defaults: isolatedDefaults())

        // Start refresh #1 — it blocks awaiting the scanner.
        let t1: Task<Void, Never> = Task { @MainActor in await inv.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(inv.isRefreshing, "first refresh should mark isRefreshing")

        // Start refresh #2 — also blocked.
        let t2: Task<Void, Never> = Task { @MainActor in await inv.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(inv.isRefreshing, "still refreshing with two in flight")

        // Resolve the older one (refresh #1) first.
        await scanner.resolve(with: [])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(inv.isRefreshing, "stale completion must NOT clear isRefreshing while #2 is still running")

        // Resolve the newer one.
        await scanner.resolve(with: [
            PortRecord(port: 9, pid: 2, processName: "x",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)])
        ])
        await t1.value
        await t2.value
        XCTAssertFalse(inv.isRefreshing)
        XCTAssertEqual(inv.records.count, 1)
        XCTAssertEqual(inv.records[0].port, 9)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PortInventoryTests/testRefreshPopulatesRecords`
Expected: fail — `refresh()` is empty.

- [ ] **Step 3: Implement `refresh()`**

In `Sources/AnyDoor/Services/PortInventory.swift`, replace the `refresh()` placeholder:

```swift
    func refresh() async {
        refreshGeneration &+= 1
        let myGen = refreshGeneration
        inflightCount += 1
        isRefreshing = true

        do {
            let scanned = try await scanner.scanTCPListening()
            inflightCount -= 1
            if myGen == refreshGeneration {
                records = scanned
                lastError = nil
            } else {
                Self.logger.debug("dropping stale scan result (gen \(myGen), now \(self.refreshGeneration))")
            }
            isRefreshing = inflightCount > 0
        } catch {
            inflightCount -= 1
            if myGen == refreshGeneration {
                lastError = .scanFailed(String(describing: error))
                // records intentionally preserved
            }
            isRefreshing = inflightCount > 0
        }
    }
```

- [ ] **Step 4: Run the new tests**

Run: `swift test --filter PortInventoryTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/PortInventory.swift Tests/AnyDoorTests/PortInventoryTests.swift
git commit -m "feat(inventory): refresh() with generation token + inflight count"
```

---

## Task 11: Implement `kill(pid:)` state machine

**Files:**
- Modify: `Sources/AnyDoor/Services/PortInventory.swift`
- Modify: `Tests/AnyDoorTests/PortInventoryTests.swift`

- [ ] **Step 1: Add the failing tests**

Append to `Tests/AnyDoorTests/PortInventoryTests.swift`:

```swift
    /// Records every kill call and lets the test choose what `SignalResult` to return.
    private final class RecordingKillScanner: PortScanning, @unchecked Sendable {
        var records: [PortRecord]
        let killHandler: (pid_t, Int32) -> SignalResult
        private(set) var killCalls: [(pid: pid_t, sig: Int32)] = []
        init(records: [PortRecord], killHandler: @escaping (pid_t, Int32) -> SignalResult) {
            self.records = records
            self.killHandler = killHandler
        }
        func scanTCPListening() async throws -> [PortRecord] { records }
        func kill(pid: pid_t, signal: Int32) -> SignalResult {
            killCalls.append((pid, signal))
            return killHandler(pid, signal)
        }
    }

    @MainActor
    func testKillEPERMRecordsPermissionDenied() async {
        let r = PortRecord(port: 80, pid: 99, processName: "root-thing",
                           executablePath: nil, commandLine: nil,
                           binds: [PortBind(address: "*", family: .ipv4)])
        let scanner = RecordingKillScanner(records: [r]) { _, _ in .failure(.EPERM) }
        let inv = PortInventory(scanner: scanner, defaults: isolatedDefaults())
        await inv.refresh()
        await inv.kill(pid: 99)
        XCTAssertEqual(inv.failedKillPIDs[99]?.reason, .permissionDenied)
        XCTAssertFalse(inv.killingPIDs.contains(99))
    }

    @MainActor
    func testKillESRCHIsNotRecordedAsFailure() async {
        let r = PortRecord(port: 80, pid: 99, processName: "x",
                           executablePath: nil, commandLine: nil,
                           binds: [PortBind(address: "*", family: .ipv4)])
        let scanner = RecordingKillScanner(records: [r]) { _, _ in .failure(.ESRCH) }
        let inv = PortInventory(scanner: scanner, defaults: isolatedDefaults())
        await inv.refresh()
        scanner.records = [] // pretend the process is already gone
        await inv.kill(pid: 99)
        XCTAssertNil(inv.failedKillPIDs[99])
        XCTAssertFalse(inv.killingPIDs.contains(99))
    }

    @MainActor
    func testKillSuccessEscalatesToSIGKILLWhenProcessSurvives() async {
        let r = PortRecord(port: 80, pid: 99, processName: "stubborn",
                           executablePath: nil, commandLine: nil,
                           binds: [PortBind(address: "*", family: .ipv4)])
        let scanner = RecordingKillScanner(records: [r]) { _, _ in .success }
        let inv = PortInventory(scanner: scanner, defaults: isolatedDefaults())
        await inv.refresh()
        // Pid still present after SIGTERM, so SIGKILL should be sent.
        await inv.kill(pid: 99)
        let sigs = scanner.killCalls.map(\.sig)
        XCTAssertTrue(sigs.contains(SIGTERM))
        XCTAssertTrue(sigs.contains(SIGKILL))
    }

    @MainActor
    func testKillSuccessNoEscalateWhenProcessExits() async {
        let r = PortRecord(port: 80, pid: 99, processName: "fast-exit",
                           executablePath: nil, commandLine: nil,
                           binds: [PortBind(address: "*", family: .ipv4)])
        let scanner = RecordingKillScanner(records: [r]) { _, _ in .success }
        let inv = PortInventory(scanner: scanner, defaults: isolatedDefaults())
        await inv.refresh()
        // After SIGTERM, simulate the process being gone before refresh checks.
        scanner.records = []
        await inv.kill(pid: 99)
        let sigs = scanner.killCalls.map(\.sig)
        XCTAssertEqual(sigs, [SIGTERM])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PortInventoryTests/testKillEPERMRecordsPermissionDenied`
Expected: fail — `kill(pid:)` is empty.

- [ ] **Step 3: Implement `kill(pid:)`**

In `Sources/AnyDoor/Services/PortInventory.swift`, replace the `kill(pid:)` placeholder:

```swift
    func kill(pid: pid_t) async {
        killingPIDs.insert(pid)

        // Step 1: SIGTERM
        switch scanner.kill(pid: pid, signal: SIGTERM) {
        case .failure(.ESRCH):
            // Process already gone — treat as success.
            await refresh()
            killingPIDs.remove(pid)
            return
        case .failure(let code):
            let reason: KillFailure.Reason =
                (code == .EPERM) ? .permissionDenied : .other(code.rawValue)
            failedKillPIDs[pid] = KillFailure(reason: reason, timestamp: .now)
            scheduleAutoDismiss(for: pid)
            killingPIDs.remove(pid)
            return
        case .success:
            break
        }

        // Step 2: give the process time to handle SIGTERM, then re-scan.
        try? await Task.sleep(for: .milliseconds(500))
        await refresh()

        // Step 3: if still alive, escalate.
        if records.contains(where: { $0.pid == pid }) {
            switch scanner.kill(pid: pid, signal: SIGKILL) {
            case .success:
                try? await Task.sleep(for: .milliseconds(200))
                await refresh()
            case .failure(.ESRCH):
                await refresh()
            case .failure(let code):
                let reason: KillFailure.Reason =
                    (code == .EPERM) ? .permissionDenied : .other(code.rawValue)
                failedKillPIDs[pid] = KillFailure(reason: reason, timestamp: .now)
                scheduleAutoDismiss(for: pid)
            }
        }

        killingPIDs.remove(pid)
    }

    private func scheduleAutoDismiss(for pid: pid_t) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                self?.failedKillPIDs.removeValue(forKey: pid)
            }
        }
    }
```

- [ ] **Step 4: Run the kill tests**

Run: `swift test --filter PortInventoryTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/PortInventory.swift Tests/AnyDoorTests/PortInventoryTests.swift
git commit -m "feat(inventory): pid-level kill with SIGTERM→SIGKILL fallback"
```

---

## Task 12: Add derived views — `filteredRecords` + `groupedByProcess`

**Files:**
- Modify: `Sources/AnyDoor/Services/PortInventory.swift`
- Modify: `Tests/AnyDoorTests/PortInventoryTests.swift`

- [ ] **Step 1: Add the failing tests**

Append to `Tests/AnyDoorTests/PortInventoryTests.swift`:

```swift
    @MainActor
    func testFilteredEmptyQueryReturnsPortAscending() async {
        let recs = [
            PortRecord(port: 5000, pid: 1, processName: "a", executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
            PortRecord(port: 80, pid: 2, processName: "b", executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
            PortRecord(port: 3000, pid: 3, processName: "c", executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
        ]
        let inv = PortInventory(scanner: StubScanner(records: recs), defaults: isolatedDefaults())
        await inv.refresh()
        XCTAssertEqual(inv.filteredRecords.map(\.port), [80, 3000, 5000])
    }

    @MainActor
    func testSearchPriorityPortBeforeNameBeforePid() async {
        let recs = [
            PortRecord(port: 3000, pid: 99, processName: "node",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
            PortRecord(port: 8080, pid: 30,  processName: "java",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
        ]
        let inv = PortInventory(scanner: StubScanner(records: recs), defaults: isolatedDefaults())
        await inv.refresh()
        inv.searchText = "30"
        // Port :3000 matches the "30" substring; pid 30 also matches. Port should come first.
        XCTAssertEqual(inv.filteredRecords.map(\.port), [3000, 8080])
    }

    @MainActor
    func testSearchIsCaseInsensitive() async {
        let recs = [
            PortRecord(port: 1, pid: 1, processName: "NodeProcess",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)])
        ]
        let inv = PortInventory(scanner: StubScanner(records: recs), defaults: isolatedDefaults())
        await inv.refresh()
        inv.searchText = "node"
        XCTAssertEqual(inv.filteredRecords.count, 1)
    }

    @MainActor
    func testGroupedByProcessSortsByNameThenPort() async {
        let recs = [
            PortRecord(port: 5000, pid: 10, processName: "bravo",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
            PortRecord(port: 80, pid: 10, processName: "bravo",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
            PortRecord(port: 22, pid: 20, processName: "alpha",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
        ]
        let inv = PortInventory(scanner: StubScanner(records: recs), defaults: isolatedDefaults())
        await inv.refresh()
        let groups = inv.groupedByProcess
        XCTAssertEqual(groups.map(\.processName), ["alpha", "bravo"])
        XCTAssertEqual(groups[1].ports.map(\.port), [80, 5000])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PortInventoryTests/testFilteredEmptyQueryReturnsPortAscending`
Expected: build error — `filteredRecords` / `groupedByProcess` undefined.

- [ ] **Step 3: Implement the derived views**

Append inside the `PortInventory` class (before the closing brace) in `Sources/AnyDoor/Services/PortInventory.swift`:

```swift
    // MARK: - Derived views

    var filteredRecords: [PortRecord] {
        guard !searchText.isEmpty else {
            return records.sorted { $0.port < $1.port }
        }
        let q = searchText.lowercased()
        var seen = Set<PortRecord.ID>()
        var ordered: [PortRecord] = []
        func add(_ bucket: [PortRecord]) {
            for r in bucket where !seen.contains(r.id) {
                seen.insert(r.id)
                ordered.append(r)
            }
        }
        add(records.filter { String($0.port).contains(q) })
        add(records.filter { $0.processName.lowercased().contains(q) })
        add(records.filter { String($0.pid).contains(q) })
        return ordered
    }

    var groupedByProcess: [ProcessGroup] {
        let grouped = Dictionary(grouping: filteredRecords, by: \.pid)
        return grouped.map { (pid, recs) in
            ProcessGroup(
                pid: pid,
                processName: recs.first?.processName ?? "",
                ports: recs.sorted { $0.port < $1.port }
            )
        }
        .sorted {
            $0.processName.localizedCaseInsensitiveCompare($1.processName) == .orderedAscending
        }
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter PortInventoryTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/PortInventory.swift Tests/AnyDoorTests/PortInventoryTests.swift
git commit -m "feat(inventory): filteredRecords (priority search) + groupedByProcess"
```

---

## Task 13: Make `HoverPopover` key-focus-capable

**Files:**
- Modify: `Sources/AnyDoor/Views/HoverPopover.swift`

This is a UI infrastructure change. No new tests; verified via the manual QA gate in Task 21.

- [ ] **Step 1: Replace the `NSWindow` with a key-capable `NSPanel`**

Edit `Sources/AnyDoor/Views/HoverPopover.swift`. Replace the contents with:

```swift
import SwiftUI
import AppKit
import Observation

/// Hover-triggered NSPanel popover.
///
/// Used by both App Shortcuts (`needsKeyFocus = false`, read-only) and Port Manager
/// (`needsKeyFocus = true`, needs to receive text input and local key events).
///
/// Lifecycle:
/// - Trigger view installs `onHover` that arms the gate after 400ms.
/// - Popover stays open while either trigger or popover is hovered (gate manages).
/// - Closes 300ms after both lose hover, OR immediately via `hide()`.
@MainActor
@Observable
final class HoverPopover {
    /// True while the underlying panel is keyWindow. Read by MenuBarView.onDisappear
    /// to avoid hiding the popover when the menu bar panel collapses because we just
    /// took key focus.
    private(set) var isHoldingFocus: Bool = false

    private let panel: KeyableHoverPanel
    private let hostingController: NSHostingController<AnyView>
    private var hideTask: Task<Void, Never>?
    private var keyObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?

    /// Set to `true` for popovers whose SwiftUI content needs first-responder focus
    /// (e.g. TextField). Leave `false` for read-only popovers — they keep the
    /// historical "never becomes key" behaviour.
    var needsKeyFocus: Bool = false {
        didSet { panel.allowKey = needsKeyFocus }
    }

    init<Content: View>(@ViewBuilder content: () -> Content) {
        let controller = NSHostingController(rootView: AnyView(content()))
        controller.sizingOptions = [.preferredContentSize]
        self.hostingController = controller

        let panel = KeyableHoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentViewController = controller
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        self.panel = panel

        // Track key state so MenuBarView can guard onDisappear.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isHoldingFocus = true }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isHoldingFocus = false }
        }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func updateContent<Content: View>(@ViewBuilder content: () -> Content) {
        hostingController.rootView = AnyView(content())
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0 && fitting.height > 0 {
            panel.setContentSize(fitting)
        }
    }

    /// Show the popover anchored to the right side of `referenceFrame` (screen coordinates).
    func show(anchoredTo referenceFrame: NSRect) {
        hideTask?.cancel()
        hideTask = nil

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(referenceFrame) }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero

        let size = panel.frame.size
        let rightX = referenceFrame.maxX + 4
        let leftX = referenceFrame.minX - 4 - size.width
        let originX = (rightX + size.width <= screenFrame.maxX) ? rightX : leftX
        let originY = max(screenFrame.minY,
                          min(referenceFrame.midY - size.height / 2,
                              screenFrame.maxY - size.height))

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFrontRegardless()
        if needsKeyFocus {
            panel.makeKey()
        }
    }

    func scheduleHide(after delay: TimeInterval = 0.3) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.panel.orderOut(nil)
        }
    }

    func keepOpen() {
        hideTask?.cancel()
        hideTask = nil
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel.orderOut(nil)
    }
}

/// NSPanel subclass whose key-eligibility is controlled by an opt-in flag.
/// App Shortcuts uses `allowKey = false` (read-only), Port Manager uses `true`.
final class KeyableHoverPanel: NSPanel {
    var allowKey: Bool = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

// MARK: - HoverGate (unchanged plus new reset())

@MainActor
@Observable
final class HoverGate {
    private(set) var isShown = false
    private var triggerHovered = false
    private var popoverHovered = false
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    var onShow: () -> Void = {}
    var onHide: () -> Void = {}

    func triggerHover(_ hovered: Bool) {
        triggerHovered = hovered
        if hovered { scheduleShow() } else { scheduleHide() }
    }

    func popoverHover(_ hovered: Bool) {
        popoverHovered = hovered
        if hovered { showTask?.cancel(); hideTask?.cancel() }
        else { scheduleHide() }
    }

    func showImmediately() {
        showTask?.cancel()
        if !isShown {
            isShown = true
            onShow()
        }
    }

    /// Forcibly reset all tracked hover state. Used by the port-manager ESC
    /// path to clear the gate before the popover is dismissed programmatically.
    func reset() {
        showTask?.cancel()
        hideTask?.cancel()
        showTask = nil
        hideTask = nil
        triggerHovered = false
        popoverHovered = false
        if isShown {
            isShown = false
            onHide()
        }
    }

    private func scheduleShow() {
        guard !isShown else { return }
        hideTask?.cancel()
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, self.triggerHovered else { return }
            self.isShown = true
            self.onShow()
        }
    }

    private func scheduleHide() {
        guard isShown else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            guard !self.triggerHovered && !self.popoverHovered else { return }
            self.isShown = false
            self.onHide()
        }
    }
}
```

- [ ] **Step 2: Build and run existing tests**

Run: `swift build`
Expected: clean build.

Run: `swift test`
Expected: all existing tests still pass (App Shortcuts behaviour preserved because `needsKeyFocus` defaults to `false`).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/HoverPopover.swift
git commit -m "refactor(hover): opt-in key-focus via NSPanel + reset gate helper"
```

---

## Task 14: Generalise `PanelSettingsView` hotkey filter for any submenu

**Files:**
- Modify: `Sources/AnyDoor/Views/PanelSettingsView.swift`

- [ ] **Step 1: Read the current code**

Open `Sources/AnyDoor/Views/PanelSettingsView.swift`. The function around line 90 is:

```swift
    @ViewBuilder
    private func hotkeyField(for entry: PanelEntry) -> some View {
        if case .builtin(.appShortcuts) = entry.source {
            // The submenu itself has no hotkey (children do); reserve column width
            // for alignment without showing a meaningless placeholder.
            Color.clear.frame(width: 130)
        } else {
            HotkeyRecorder(hotkey: .constant(entry.hotkey)) { newValue in
                handleHotkeyChange(entry: entry, newValue: newValue)
            }
            .frame(width: 130, alignment: .trailing)
        }
    }
```

- [ ] **Step 2: Replace with the generalised filter**

Replace the function body with:

```swift
    @ViewBuilder
    private func hotkeyField(for entry: PanelEntry) -> some View {
        // Any submenu-kind builtin has no hotkey (children carry their own, or
        // the submenu is opened by hovering). Reserve the column width so the
        // grid stays aligned.
        if case let .builtin(item) = entry.source, item.kind == .submenu {
            Color.clear.frame(width: 130)
        } else {
            HotkeyRecorder(hotkey: .constant(entry.hotkey)) { newValue in
                handleHotkeyChange(entry: entry, newValue: newValue)
            }
            .frame(width: 130, alignment: .trailing)
        }
    }
```

- [ ] **Step 3: Build and run tests**

Run: `swift build`
Run: `swift test`
Expected: all pass; no regressions.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/PanelSettingsView.swift
git commit -m "fix(settings): hide hotkey recorder for any submenu-kind builtin"
```

---

## Task 15: Build `PortListView` with `PortRowView` and `PortStatusDot`

**Files:**
- Create: `Sources/AnyDoor/Views/PortListView.swift`

UI tasks are validated by the build (no unit tests for SwiftUI views).

- [ ] **Step 1: Create the file**

Create `Sources/AnyDoor/Views/PortListView.swift`:

```swift
import SwiftUI

struct PortListView: View {
    @Bindable var inventory: PortInventory

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(inventory.filteredRecords) { record in
                    PortRowView(record: record, inventory: inventory)
                    Divider()
                }
            }
        }
    }
}

struct PortRowView: View {
    let record: PortRecord
    @Bindable var inventory: PortInventory
    @State private var isHovered = false

    private var rowState: PortStatusDot.State {
        if inventory.failedKillPIDs[record.pid] != nil { return .failed }
        if inventory.killingPIDs.contains(record.pid)  { return .killing }
        return .listening
    }

    var body: some View {
        HStack(spacing: 12) {
            PortStatusDot(state: rowState).frame(width: 10)
            Text(":\(record.port)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(minWidth: 60, alignment: .leading)
            Text(record.processName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("PID \(record.pid)")
                .font(.caption)
                .foregroundStyle(.secondary)
            trailingControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.white.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(tooltipText)
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch rowState {
        case .killing:
            ProgressView().controlSize(.small)
        case .failed:
            Button {
                inventory.dismissError(for: record.pid)
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        case .listening:
            if isHovered {
                Button {
                    Task { await inventory.kill(pid: record.pid) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("kill PID \(record.pid)")
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
    }

    private var tooltipText: String {
        var lines: [String] = [record.processName]
        if let cmd = record.commandLine, !cmd.isEmpty, cmd != record.processName {
            lines.append(cmd)
        }
        if let path = record.executablePath, !path.isEmpty { lines.append(path) }
        lines.append("")
        lines.append("Binds:")
        for bind in record.binds {
            lines.append("  \(bind.address) (\(bind.family.rawValue))")
        }
        if let failure = inventory.failedKillPIDs[record.pid] {
            lines.append("")
            switch failure.reason {
            case .permissionDenied:
                lines.append("kill 失败：权限不足（系统/其他用户进程）")
            case .processGone:
                lines.append("kill 失败：进程已退出")
            case .other(let code):
                lines.append("kill 失败 (errno: \(code))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct PortStatusDot: View {
    enum State { case listening, killing, failed }
    let state: State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch state {
        case .listening: return .green
        case .killing:   return .gray
        case .failed:    return .red
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/PortListView.swift
git commit -m "feat(ui): PortListView with hover-revealed kill icon"
```

---

## Task 16: Build `PortTreeView` with bind summary

**Files:**
- Create: `Sources/AnyDoor/Views/PortTreeView.swift`

- [ ] **Step 1: Create the file**

Create `Sources/AnyDoor/Views/PortTreeView.swift`:

```swift
import SwiftUI

struct PortTreeView: View {
    @Bindable var inventory: PortInventory

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(inventory.groupedByProcess) { group in
                    PortProcessGroupRow(group: group, inventory: inventory)
                    Divider()
                }
            }
        }
    }
}

private struct PortProcessGroupRow: View {
    let group: ProcessGroup
    @Bindable var inventory: PortInventory
    @State private var isExpanded: Bool = false
    @State private var isHeaderHovered: Bool = false

    private var rowState: PortStatusDot.State {
        if inventory.failedKillPIDs[group.pid] != nil { return .failed }
        if inventory.killingPIDs.contains(group.pid)  { return .killing }
        return .listening
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                ForEach(group.ports) { record in
                    leaf(record)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            PortStatusDot(state: rowState).frame(width: 10)
            Text(group.processName)
                .fontWeight(.semibold)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("PID \(group.pid)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isExpanded {
                Text("\(group.ports.count)")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            trailingControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHeaderHovered ? Color.white.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHeaderHovered = $0 }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch rowState {
        case .killing:
            ProgressView().controlSize(.small)
        case .failed:
            Button {
                inventory.dismissError(for: group.pid)
            } label: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        case .listening:
            if isHeaderHovered {
                Button {
                    Task { await inventory.kill(pid: group.pid) }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("kill PID \(group.pid)")
            } else {
                Color.clear.frame(width: 16, height: 16)
            }
        }
    }

    private func leaf(_ record: PortRecord) -> some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 28)
            Text(":\(record.port)")
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 60, alignment: .leading)
            Text(bindSummary(for: record))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(record.binds.map { "\($0.address) (\($0.family.rawValue))" }.joined(separator: "\n"))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func bindSummary(for record: PortRecord) -> String {
        let binds = record.binds
        switch binds.count {
        case 0:
            return ""
        case 1:
            return binds[0].address
        case 2:
            if Set(binds.map(\.family)) == Set([.ipv4, .ipv6]) {
                let v4 = binds.first(where: { $0.family == .ipv4 })?.address ?? ""
                let v6 = binds.first(where: { $0.family == .ipv6 })?.address ?? ""
                return "\(v4) · \(v6)"
            }
            return binds.map(\.address).joined(separator: " · ")
        default:
            return "\(binds.count) binds"
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/PortTreeView.swift
git commit -m "feat(ui): PortTreeView with collapsible process groups + bind summary"
```

---

## Task 17: Assemble `PortManagerPopoverView` + header + toolbar + banner + keyboard monitor

**Files:**
- Create: `Sources/AnyDoor/Views/PortManagerPopoverView.swift`

- [ ] **Step 1: Create the file**

Create `Sources/AnyDoor/Views/PortManagerPopoverView.swift`:

```swift
import SwiftUI
import AppKit

struct PortManagerPopoverView: View {
    @Bindable var inventory: PortInventory
    var onHoverChange: (Bool) -> Void
    var onClose: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PortManagerHeader(
                inventory: inventory,
                searchFocused: $searchFocused
            )
            if let err = inventory.lastError {
                PortScanErrorBanner(error: err) {
                    Task { await inventory.refresh() }
                }
            }
            content
            Divider()
            PortManagerToolbar(inventory: inventory)
        }
        .frame(width: 340)
        .frame(minHeight: 280, maxHeight: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            await inventory.refresh()
            searchFocused = true
        }
        .onHover(perform: onHoverChange)
        .background(KeyboardMonitor(inventory: inventory, onClose: onClose))
    }

    @ViewBuilder
    private var content: some View {
        if inventory.isRefreshing && inventory.records.isEmpty {
            VStack {
                Spacer()
                ProgressView("扫描中...")
                Spacer()
            }
        } else if inventory.filteredRecords.isEmpty {
            VStack {
                Spacer()
                Text("无匹配的端口").foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            switch inventory.viewMode {
            case .list: PortListView(inventory: inventory)
            case .tree: PortTreeView(inventory: inventory)
            }
        }
    }
}

private struct PortManagerHeader: View {
    @Bindable var inventory: PortInventory
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(.secondary)
            TextField("Search...", text: $inventory.searchText)
                .textFieldStyle(.plain)
                .focused(searchFocused)
            ZStack {
                if inventory.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(inventory.filteredRecords.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

private struct PortManagerToolbar: View {
    @Bindable var inventory: PortInventory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await inventory.refresh() }
            } label: {
                HStack {
                    Label("Refresh", systemImage: "arrow.clockwise")
                    Spacer()
                    Text("⌘R").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)

            Button {
                inventory.viewMode = (inventory.viewMode == .list) ? .tree : .list
            } label: {
                HStack {
                    Label(
                        inventory.viewMode == .list ? "Tree View" : "List View",
                        systemImage: "list.bullet.indent"
                    )
                    Spacer()
                    Text("⌘T").foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

private struct PortScanErrorBanner: View {
    let error: PortInventoryError
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message).font(.caption)
            Spacer()
            Button(action: retry) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.yellow.opacity(0.15))
    }

    private var message: String {
        switch error {
        case .scanFailed(let detail):
            return "刷新失败：\(detail)"
        }
    }
}

/// Installs a local NSEvent key-down monitor while mounted. Handles ⌘R, ⌘T, ESC.
private struct KeyboardMonitor: NSViewRepresentable {
    @Bindable var inventory: PortInventory
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(inventory: inventory, onClose: onClose)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onClose = onClose
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        let inventory: PortInventory
        var onClose: () -> Void
        private var monitor: Any?

        init(inventory: PortInventory, onClose: @escaping () -> Void) {
            self.inventory = inventory
            self.onClose = onClose
        }

        func install() {
            uninstall()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let cmd = event.modifierFlags.contains(.command)
                let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if cmd && chars == "r" {
                    Task { @MainActor in await self.inventory.refresh() }
                    return nil
                }
                if cmd && chars == "t" {
                    Task { @MainActor in
                        self.inventory.viewMode = (self.inventory.viewMode == .list) ? .tree : .list
                    }
                    return nil
                }
                if event.keyCode == 53 { // ESC
                    Task { @MainActor in
                        if self.inventory.searchText.isEmpty {
                            self.onClose()
                        } else {
                            self.inventory.searchText = ""
                        }
                    }
                    return nil
                }
                return event
            }
        }

        func uninstall() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/PortManagerPopoverView.swift
git commit -m "feat(ui): PortManagerPopoverView assembly with header, toolbar, keyboard monitor"
```

---

## Task 18: Wire `PortManagerPopoverView` into `MenuBarView`

**Files:**
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift`

- [ ] **Step 1: Update MenuBarView**

Open `Sources/AnyDoor/Views/MenuBarView.swift`. We need to:

1. Replace the single `triggerFrame: NSRect` state with a dictionary `triggerFrames: [BuiltinItem: NSRect]` keyed by submenu item.
2. Extend `rowView(for:)` to handle any `.submenu`-kind builtin (currently special-cases `.appShortcuts`).
3. Track which submenu is "active" so `gate.onShow` can mount the right popover.
4. Add `mountPopoverContent(for:)` switch on `BuiltinItem` (App Shortcuts keeps current behaviour with `AppSwitcher.toggle` calls; Port Manager mounts `PortManagerPopoverView` with `needsKeyFocus = true`).
5. Make `onDisappear` guard on `popover.isHoldingFocus`.

Replace the file contents with:

```swift
import SwiftUI
import AppKit

struct MenuBarView: View {
    @State private var panel = PanelStore.shared
    @State private var popover = HoverPopover { EmptyView() }
    @State private var gate = HoverGate()
    @State private var triggerFrames: [BuiltinItem: NSRect] = [:]
    @State private var activeSubmenu: BuiltinItem? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("AnyDoor").font(.headline)
                Spacer()
                let count = panel.topLevelEntries.filter(\.isVisible).count
                Text("\(count) 个已启用").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 4)

            GlassEffectContainer(spacing: 2) {
                VStack(spacing: 2) {
                    ForEach(panel.topLevelEntries.filter(\.isVisible)) { entry in
                        rowView(for: entry)
                    }
                }
            }
            .padding(.horizontal, 4)

            HStack(spacing: 8) {
                SettingsLink { Label("设置", systemImage: "gear") }
                    .buttonStyle(.glass)
                    .simultaneousGesture(TapGesture().onEnded {
                        NSApplication.shared.activate()
                    })
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("退出", systemImage: "power")
                }.buttonStyle(.glass)
                Spacer()
            }
            .focusEffectDisabled()
            .padding(.horizontal, 8).padding(.bottom, 4)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .frame(width: 260)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await panel.refreshAll()
        }
        .onAppear { wireGate() }
        .onDisappear {
            // Don't hide if the popover took key focus deliberately (port-manager
            // search field). Otherwise hide as before.
            if !popover.isHoldingFocus { popover.hide() }
        }
    }

    @ViewBuilder
    private func rowView(for entry: PanelEntry) -> some View {
        if case let .builtin(item) = entry.source, item.kind == .submenu {
            PanelRowView(
                entry: entry,
                onToggle: {},
                onAction: {},
                onSubmenu: { triggerSubmenu(item) },
                onPermission: openPermissionsSettings
            )
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear {
                        triggerFrames[item] = proxy.frame(in: .global)
                    }.onChange(of: proxy.frame(in: .global)) { _, new in
                        triggerFrames[item] = new
                    }
                }
            )
            .onHover { hovered in
                if hovered { activeSubmenu = item }
                gate.triggerHover(hovered)
            }
        } else {
            PanelRowView(
                entry: entry,
                onToggle: {
                    if case let .builtin(builtin) = entry.source {
                        Task { await panel.toggle(builtin) }
                    }
                },
                onAction: {
                    if case let .builtin(builtin) = entry.source {
                        Task { await panel.run(builtin) }
                    }
                },
                onSubmenu: {},
                onPermission: openPermissionsSettings
            )
        }
    }

    private func wireGate() {
        gate.onShow = {
            guard let item = activeSubmenu else { return }
            mountPopoverContent(for: item)
            popover.show(anchoredTo: convertedTriggerFrame(for: item))
        }
        gate.onHide = {
            popover.scheduleHide()
            popover.needsKeyFocus = false
        }
    }

    private func mountPopoverContent(for item: BuiltinItem) {
        switch item {
        case .appShortcuts:
            popover.needsKeyFocus = false
            popover.updateContent {
                AppShortcutsPopoverView(
                    entries: panel.appShortcutChildren,
                    onHoverChange: { gate.popoverHover($0) },
                    onSelect: { entry in
                        if case let .appShortcut(id) = entry.source,
                           let binding = panel.binding(id: id) {
                            AppSwitcher.toggle(
                                bundleID: binding.appBundleID,
                                appPath: binding.appPath
                            )
                        }
                    },
                    appPath: { entry in
                        guard case let .appShortcut(id) = entry.source,
                              let binding = panel.binding(id: id) else { return nil }
                        return binding.appPath
                    }
                )
            }
        case .portManager:
            popover.needsKeyFocus = true
            popover.updateContent {
                PortManagerPopoverView(
                    inventory: PortInventory.shared,
                    onHoverChange: { gate.popoverHover($0) },
                    onClose: {
                        PortInventory.shared.searchText = ""
                        gate.reset()
                        popover.hide()
                    }
                )
            }
        default:
            break
        }
    }

    /// Convert the panel-local rect to screen coordinates by adding the menu bar
    /// window's origin. Same approach as the previous single-trigger implementation.
    private func convertedTriggerFrame(for item: BuiltinItem) -> NSRect {
        let local = triggerFrames[item] ?? .zero
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return local }
        return window.convertToScreen(local)
    }

    private func triggerSubmenu(_ item: BuiltinItem) {
        activeSubmenu = item
        gate.showImmediately()
    }

    private func openPermissionsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

Notes for the implementer:

- The existing file imports may include only `SwiftUI` and `AppKit`. Match the existing import list rather than adding others.
- `AppShortcutsPopoverView`'s initializer surface (`entries:`/`onHoverChange:`/`onSelect:`/`appPath:`) is exactly what the current code uses — do not change it. The replacement preserves the App Shortcuts behaviour 1:1; only the data plumbing through `triggerFrames` and `activeSubmenu` is new.
- `AppSwitcher.toggle(bundleID:appPath:)` is the existing call used for App Shortcuts taps. Keep it.
- `PortInventory.shared` is accessed from the closure. If Swift 6 actor isolation flags this as an issue, change the closure to wrap the body in `Task { @MainActor in ... }` or import the singleton through a captured local.

- [ ] **Step 2: Verify `PanelStore` API surface is unchanged**

Sanity-check that the helpers used by the App Shortcuts branch still exist:

```bash
grep -n 'func binding\|appShortcutChildren' Sources/AnyDoor/Services/PanelStore.swift
```

Expected: both are present (`binding(id:)` at ~line 218; `appShortcutChildren` declared near the top).

- [ ] **Step 3: Build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 4: Run all tests**

Run: `swift test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/MenuBarView.swift
git commit -m "feat(ui): wire port manager popover through hover dispatch"
```

---

## Task 19: Manual QA pass

This task is a checklist, not a code change. Mark each item as done after performing it.

- [ ] **Step 1: Build and launch the app**

Run: `swift run AnyDoor`

The app should appear in the menu bar with the existing door icon. macOS may prompt for accessibility permission — grant it.

- [ ] **Step 2: Verify port-manager entry is present in the menu**

Click the menu bar icon. The panel should list all existing entries plus a new "端口管理" row near the bottom.

- [ ] **Step 3: Verify Settings shows no hotkey recorder for the new row**

Open Settings → Panel tab. The "端口管理" row should display the type badge "系统 · 子菜单" and have no hotkey input field (the same alignment column reserved for App Shortcuts).

- [ ] **Step 4: Hover the port-manager row**

After ~400ms, a popover should appear to the right of the menu bar panel. It should show:

- Globe icon, search field (with cursor), count capsule.
- A scrolling list of `:port  process  PID xxxxx` rows.
- Bottom toolbar with "Refresh ⌘R" and "Tree View ⌘T" entries.

- [ ] **Step 5: Verify search**

Type "node" (or any process name visible in the list). The list should filter live and the count capsule updates.

Type a port number (e.g. `30`) — port-matching rows appear before name-matching ones.

Press ESC. The search clears; press ESC again — the popover closes and reopens cleanly on the next hover.

- [ ] **Step 6: Verify view toggle**

Press ⌘T. View flips to tree mode with collapsed process groups. Click a chevron to expand; verify leaf rows show `:port` plus a bind summary like `*` or `127.0.0.1 · ::1`.

Press ⌘T again to flip back. Quit the app and relaunch — the last-used view should persist.

- [ ] **Step 7: Verify kill (user process)**

Start a test listener in another terminal:

```bash
python3 -m http.server 9999 &
```

Wait a few seconds, press ⌘R in the popover. Find the `:9999` row, hover it, click the `xmark.circle.fill`. Within ~1 second the row should disappear.

`ps aux | grep 9999` should show no remaining process.

- [ ] **Step 8: Verify kill (root process)**

Find a row owned by a system process (e.g. `ControlCenter`). Hover and click kill. The row should show a red error icon with a tooltip saying "kill 失败：权限不足（系统/其他用户进程）". The indicator should disappear after ~3 seconds. The process keeps running.

- [ ] **Step 9: Verify the menu bar panel doesn't auto-close**

While typing in the search field, look at the menu bar panel — it should remain visible behind the popover. If the menu bar panel collapses when the popover takes focus, **the key-focus implementation needs the fallback path** (local NSEvent monitor without taking key focus). Document the observation, then switch the popover to `needsKeyFocus = false` in `MenuBarView.mountPopoverContent(for: .portManager)` and reroute printable keys via the existing `KeyboardMonitor`. (This contingency is also in the design spec under "Fallback if MenuBarExtra still collapses".)

- [ ] **Step 10: Verify App Shortcuts is unaffected**

Hover App Shortcuts; the existing popover should appear with no typing cursor, no app activation steal, and behave exactly as before.

- [ ] **Step 11: Commit any tweaks**

If the QA pass required spec-fallback tweaks (e.g. dropping `needsKeyFocus`), commit them as a follow-up:

```bash
git add Sources/AnyDoor/Views/MenuBarView.swift
git commit -m "fix(ui): use no-key-focus fallback for port manager popover"
```

Otherwise mark this task complete with no commit.

---

## Self-Review Checklist (for the planning agent only)

Before handing off to executing-plans:

- [ ] Every spec section has a corresponding task (BuiltinItem, HotkeyAction-deferred, PortScanner, PortInventory, UI layer, error handling, testing, manual QA).
- [ ] No placeholders, no "TBD"s in the plan body.
- [ ] All type names match across tasks: `PortRecord`, `PortBind`, `AddressFamily`, `SignalResult`, `PortScanning`, `SubprocessRunning`, `SubprocessResult`, `SubprocessError`, `PortScanError`, `PortInventory`, `ViewMode`, `KillFailure`, `PortInventoryError`, `ProcessGroup`, `LsofRunner`, `KeyableHoverPanel`, `HoverGate`, `HoverPopover`, `PortListView`, `PortRowView`, `PortStatusDot`, `PortTreeView`, `PortManagerPopoverView`, `KeyboardMonitor`.
- [ ] Method names consistent: `parseLsofOutput`, `parseProcArgs`, `parseAddressPort`, `decodeLsofEscapes`, `scanTCPListening`, `kill(pid:signal:)`, `refresh()`, `kill(pid:)`, `dismissError(for:)`, `filteredRecords`, `groupedByProcess`, `gate.reset()`, `needsKeyFocus`, `isHoldingFocus`.
- [ ] Generation token + inflightCount semantics covered by `testIsRefreshingClearsOnlyWhenAllInflightFinish`.
- [ ] ESRCH success semantics covered at both SIGTERM and SIGKILL sites by tests.
- [ ] No new dependencies (only `OSAllocatedUnfairLock` from `os`, already available).
- [ ] All commits use Conventional Commits in English.

---

## Execution Note

Tasks 1–18 modify code with tests; Task 19 is a manual QA gate. The plan assumes the agent has macOS available to run `swift test` (XCTest on macOS). Tests cannot run in a sandbox without a working macOS toolchain.
