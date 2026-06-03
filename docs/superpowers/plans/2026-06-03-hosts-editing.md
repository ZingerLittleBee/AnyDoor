# Hosts Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users create/edit/delete named host profiles, activate any subset (merged), and apply them to `/etc/hosts` via a privileged helper, without ever modifying the system's own hosts content.

**Architecture:** A pure-logic `HostsFile` parses `/etc/hosts` into prefix + managed-block + suffix and recomposes only the block. `HostsManager` (@MainActor @Observable, SwiftData-backed, single source of truth) owns profile CRUD and drives writes through a `HostsWriter` protocol — `PrivilegedHelperWriter` (XPC to a root LaunchDaemon registered via `SMAppService`) in production, `AppleScriptWriter` in ad-hoc/dev builds. UI is a menu-bar popover (quick activation) plus a separate editor window.

**Tech Stack:** Swift 6.2 (strict concurrency, `.v6` mode), SwiftData, SwiftUI/AppKit, ServiceManagement (`SMAppService`), NSXPC, Security framework, SPM multi-target.

**Spec:** `docs/superpowers/specs/2026-06-03-hosts-editing-design.md`

---

## Conventions for every task

- All code comments in English. UI-facing strings stay Chinese, added via `L10n` + `Localizable.xcstrings`.
- Run tests with: `swift test --filter <TestClass>` (single class) or `swift test` (all).
- Commit messages: Conventional Commits, no `Co-Authored-By`, no watermark, no `@` characters in commit/PR text.
- Build check after non-test changes: `swift build`.

## Implementation note that refines the spec

The begin/end markers live as `HostsFile` static constants (NOT in `HostsHelperShared`). The helper never parses hosts content — it only writes the final bytes it is handed — so the shared XPC target stays free of hosts-format logic. Markers use plain ASCII (no em-dash) to avoid any encoding ambiguity when round-tripping `/etc/hosts`.

---

## Task 0: SPM scaffolding for shared + helper targets

**Files:**
- Modify: `Package.swift:22-53`
- Create: `Sources/HostsHelperShared/Placeholder.swift`
- Create: `Sources/AnyDoorHostsHelper/main.swift`

- [ ] **Step 1: Add the two targets to Package.swift**

Add a library target `HostsHelperShared`, make `AnyDoor` depend on it, and add an executable target `AnyDoorHostsHelper`. Insert into the `targets:` array (after the `AnyDoor` executable target, before the test target):

```swift
        .target(
            name: "HostsHelperShared",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "AnyDoorHostsHelper",
            dependencies: ["HostsHelperShared"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
```

And add `"HostsHelperShared"` to the `AnyDoor` target's `dependencies` array (currently `Package.swift:30-34`):

```swift
            dependencies: [
                .product(name: "AskForPermission", package: "AskForPermission"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "DDC", package: "DDC.swift"),
                "HostsHelperShared",
            ],
```

- [ ] **Step 2: Create placeholder sources so the targets compile**

`Sources/HostsHelperShared/Placeholder.swift`:

```swift
// Intentionally empty; real types are added in Task 1.
```

`Sources/AnyDoorHostsHelper/main.swift`:

```swift
// Placeholder entry point; the real listener is added in Task 8.
```

- [ ] **Step 3: Verify it builds**

Run: `swift build`
Expected: builds with no errors (placeholder targets compile).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/HostsHelperShared Sources/AnyDoorHostsHelper
git commit -m "build(hosts): scaffold shared + privileged helper SPM targets"
```

---

## Task 1: XPC protocol + shared constants

**Files:**
- Create: `Sources/HostsHelperShared/HostsHelperProtocol.swift`
- Delete: `Sources/HostsHelperShared/Placeholder.swift`

- [ ] **Step 1: Define the protocol and constants**

`Sources/HostsHelperShared/HostsHelperProtocol.swift`:

```swift
import Foundation

/// Shared identifiers and the XPC contract between the AnyDoor app and the
/// privileged helper. Kept free of hosts-file parsing logic on purpose.
public enum HostsHelperConstants {
    /// Mach service name vended by the LaunchDaemon and connected to by the app.
    public static let machServiceName = "dev.bybee.AnyDoor.HostsHelper"
    /// Upper bound on a single write payload (bytes) to bound helper memory.
    public static let maxPayloadBytes = 1_048_576  // 1 MiB
}

/// XPC interface implemented by the root helper.
@objc public protocol HostsHelperProtocol {
    /// Replace `/etc/hosts` with `content`. Replies with nil on success or an
    /// error message describing the failure.
    func writeHosts(_ content: String, withReply reply: @escaping (String?) -> Void)
    /// Returns the helper's bundle/build version for diagnostics + upgrade checks.
    func helperVersion(withReply reply: @escaping (String) -> Void)
}
```

- [ ] **Step 2: Remove placeholder and build**

```bash
rm Sources/HostsHelperShared/Placeholder.swift
swift build
```
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/HostsHelperShared
git commit -m "feat(hosts): add XPC protocol and shared helper constants"
```

---

## Task 2: HostsFile parse/compose (pure logic, TDD)

**Files:**
- Create: `Sources/AnyDoor/Services/Hosts/HostsFile.swift`
- Test: `Tests/AnyDoorTests/HostsFileTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/AnyDoorTests/HostsFileTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class HostsFileTests: XCTestCase {
    private func block(_ profiles: [(String, String)]) -> String {
        HostsFile.compose(
            parsed: HostsFile.parse(""),
            activeProfiles: profiles.map { (name: $0.0, content: $0.1) }
        )
    }

    func test_parse_noMarkers_allPrefix() {
        let raw = "127.0.0.1 localhost\n255.255.255.255 broadcasthost\n"
        let p = HostsFile.parse(raw)
        XCTAssertEqual(p.prefix, raw)
        XCTAssertNil(p.managed)
        XCTAssertEqual(p.suffix, "")
    }

    func test_parse_splitsPrefixManagedSuffix() {
        let raw = [
            "127.0.0.1 localhost",
            HostsFile.beginMarker,
            "1.2.3.4 dev.example.com",
            HostsFile.endMarker,
            "9.9.9.9 after.example.com",
        ].joined(separator: "\n")
        let p = HostsFile.parse(raw)
        XCTAssertEqual(p.prefix, "127.0.0.1 localhost")
        XCTAssertEqual(p.managed, "1.2.3.4 dev.example.com")
        XCTAssertEqual(p.suffix, "9.9.9.9 after.example.com")
    }

    func test_parse_beginWithoutEnd_treatsAllAsPrefix() {
        let raw = "127.0.0.1 localhost\n\(HostsFile.beginMarker)\n1.2.3.4 x"
        let p = HostsFile.parse(raw)
        XCTAssertEqual(p.prefix, raw)
        XCTAssertNil(p.managed)
    }

    func test_compose_noActiveProfiles_removesBlock_keepsPrefix() {
        let parsed = HostsFile.Parsed(prefix: "127.0.0.1 localhost",
                                      managed: "old stuff",
                                      suffix: "")
        let out = HostsFile.compose(parsed: parsed, activeProfiles: [])
        XCTAssertFalse(out.contains(HostsFile.beginMarker))
        XCTAssertTrue(out.contains("127.0.0.1 localhost"))
    }

    func test_compose_writesBlockBetweenMarkers() {
        let parsed = HostsFile.Parsed(prefix: "127.0.0.1 localhost", managed: nil, suffix: "")
        let out = HostsFile.compose(
            parsed: parsed,
            activeProfiles: [(name: "Dev", content: "1.2.3.4 dev.example.com")]
        )
        XCTAssertTrue(out.contains(HostsFile.beginMarker))
        XCTAssertTrue(out.contains("# --- Dev ---"))
        XCTAssertTrue(out.contains("1.2.3.4 dev.example.com"))
        XCTAssertTrue(out.contains(HostsFile.endMarker))
    }

    func test_compose_preservesSuffix() {
        let parsed = HostsFile.Parsed(prefix: "127.0.0.1 localhost",
                                      managed: nil,
                                      suffix: "9.9.9.9 after.example.com")
        let out = HostsFile.compose(
            parsed: parsed,
            activeProfiles: [(name: "Dev", content: "1.2.3.4 dev")]
        )
        XCTAssertTrue(out.contains("9.9.9.9 after.example.com"))
        // suffix must come after the end marker
        let endRange = try! XCTUnwrap(out.range(of: HostsFile.endMarker))
        let suffixRange = try! XCTUnwrap(out.range(of: "9.9.9.9 after.example.com"))
        XCTAssertTrue(suffixRange.lowerBound > endRange.upperBound)
    }

    func test_compose_stripsMarkerInjectionFromProfileContent() {
        let parsed = HostsFile.Parsed(prefix: "", managed: nil, suffix: "")
        let evil = "1.2.3.4 a\n\(HostsFile.beginMarker)\n\(HostsFile.endMarker)\n5.6.7.8 b"
        let out = HostsFile.compose(
            parsed: parsed,
            activeProfiles: [(name: "Evil", content: evil)]
        )
        // exactly one begin marker and one end marker survive
        let begins = out.components(separatedBy: HostsFile.beginMarker).count - 1
        let ends = out.components(separatedBy: HostsFile.endMarker).count - 1
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(ends, 1)
    }

    func test_compose_isIdempotent() {
        let parsed = HostsFile.Parsed(prefix: "127.0.0.1 localhost", managed: nil, suffix: "tail")
        let profiles = [(name: "A", content: "1.1.1.1 a"), (name: "B", content: "2.2.2.2 b")]
        let once = HostsFile.compose(parsed: parsed, activeProfiles: profiles)
        let twice = HostsFile.compose(parsed: HostsFile.parse(once), activeProfiles: profiles)
        XCTAssertEqual(once, twice)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter HostsFileTests`
Expected: FAIL — `HostsFile` not defined.

- [ ] **Step 3: Implement HostsFile**

`Sources/AnyDoor/Services/Hosts/HostsFile.swift`:

```swift
import Foundation

/// Pure, side-effect-free parsing and composition of `/etc/hosts`.
///
/// `/etc/hosts` is treated as: prefix (system content) + an optional AnyDoor
/// managed block + suffix (also system content). AnyDoor only ever rewrites
/// the managed block; prefix and suffix are preserved verbatim.
enum HostsFile {
    static let beginMarker = "# >>> AnyDoor managed block - do not edit below this line >>>"
    static let endMarker = "# <<< AnyDoor managed block end <<<"

    struct Parsed: Equatable {
        var prefix: String
        var managed: String?
        var suffix: String
    }

    /// Split raw hosts text. When the markers are absent or malformed (begin
    /// without a following end), the whole file is treated as system prefix.
    static func parse(_ raw: String) -> Parsed {
        let lines = raw.components(separatedBy: "\n")
        guard let beginIdx = lines.firstIndex(of: beginMarker) else {
            return Parsed(prefix: raw, managed: nil, suffix: "")
        }
        let afterBegin = lines[(beginIdx + 1)...]
        guard let endOffset = afterBegin.firstIndex(of: endMarker) else {
            return Parsed(prefix: raw, managed: nil, suffix: "")
        }
        let prefix = lines[..<beginIdx].joined(separator: "\n")
        let managed = lines[(beginIdx + 1)..<endOffset].joined(separator: "\n")
        let suffix = lines[(endOffset + 1)...].joined(separator: "\n")
        return Parsed(prefix: prefix, managed: managed, suffix: suffix)
    }

    /// Recompose hosts text: preserved prefix, a freshly built managed block
    /// for the active profiles (omitted entirely when none), then preserved
    /// suffix. Output always ends with a single trailing newline.
    static func compose(parsed: Parsed, activeProfiles: [(name: String, content: String)]) -> String {
        var sections: [String] = []

        let prefix = trimTrailingNewlines(parsed.prefix)
        if !prefix.isEmpty { sections.append(prefix) }

        if !activeProfiles.isEmpty {
            var blockLines: [String] = [beginMarker]
            for profile in activeProfiles {
                blockLines.append("# --- \(sanitizeName(profile.name)) ---")
                let body = trimTrailingNewlines(sanitizeContent(profile.content))
                if !body.isEmpty { blockLines.append(body) }
            }
            blockLines.append(endMarker)
            sections.append(blockLines.joined(separator: "\n"))
        }

        let suffix = trimTrailingNewlines(parsed.suffix)
        if !suffix.isEmpty { sections.append(suffix) }

        return sections.joined(separator: "\n\n") + "\n"
    }

    /// Remove any lines from profile content that would forge our markers.
    private static func sanitizeContent(_ content: String) -> String {
        content
            .components(separatedBy: "\n")
            .filter { $0 != beginMarker && $0 != endMarker }
            .joined(separator: "\n")
    }

    /// Keep profile names single-line so they cannot break the comment header.
    private static func sanitizeName(_ name: String) -> String {
        name.replacingOccurrences(of: "\n", with: " ")
    }

    private static func trimTrailingNewlines(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter HostsFileTests`
Expected: PASS (all cases). If a whitespace assertion fails, the tests are the spec — adjust the implementation's spacing to satisfy them, not vice versa.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Hosts/HostsFile.swift Tests/AnyDoorTests/HostsFileTests.swift
git commit -m "feat(hosts): add HostsFile parse/compose with managed-block preservation"
```

---

## Task 3: HostProfile SwiftData model + schema registration

**Files:**
- Create: `Sources/AnyDoor/Models/HostProfile.swift`
- Modify: `Sources/AnyDoor/AppDelegate.swift:27-30` (ModelContainer schema)
- Test: `Tests/AnyDoorTests/HostProfileTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/AnyDoorTests/HostProfileTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AnyDoor

final class HostProfileTests: XCTestCase {
    func test_init_setsDefaultsAndTimestamps() throws {
        let p = HostProfile(name: "Dev", content: "1.2.3.4 dev")
        XCTAssertEqual(p.name, "Dev")
        XCTAssertEqual(p.content, "1.2.3.4 dev")
        XCTAssertFalse(p.isActive)
        XCTAssertEqual(p.displayOrder, 0)
        XCTAssertEqual(p.createdAt.timeIntervalSince1970,
                       p.updatedAt.timeIntervalSince1970, accuracy: 1.0)
    }

    @MainActor
    func test_persistsInInMemoryContainer() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
        let container = try ModelContainer(for: HostProfile.self, configurations: config)
        let ctx = container.mainContext
        ctx.insert(HostProfile(name: "A", content: "x", isActive: true, displayOrder: 100))
        try ctx.save()
        let rows = try ctx.fetch(FetchDescriptor<HostProfile>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isActive)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter HostProfileTests`
Expected: FAIL — `HostProfile` not defined.

- [ ] **Step 3: Implement the model**

`Sources/AnyDoor/Models/HostProfile.swift`:

```swift
import Foundation
import SwiftData

/// A user-defined hosts profile. Active profiles are merged into the AnyDoor
/// managed block in `/etc/hosts`. System hosts content is never stored here.
@Model
final class HostProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var content: String
    var isActive: Bool = false
    var displayOrder: Double = 0
    var createdAt: Date
    var updatedAt: Date

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

- [ ] **Step 4: Register in the app's ModelContainer**

Modify `Sources/AnyDoor/AppDelegate.swift:27-30` to add `HostProfile.self`:

```swift
            modelContainer = try ModelContainer(
                for: KeyBinding.self, BuiltinPreference.self, ClipboardHistoryItem.self, HostProfile.self,
                configurations: config
            )
```

- [ ] **Step 5: Run to verify pass + build**

Run: `swift test --filter HostProfileTests` (Expected: PASS)
Run: `swift build` (Expected: success)

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Models/HostProfile.swift Sources/AnyDoor/AppDelegate.swift Tests/AnyDoorTests/HostProfileTests.swift
git commit -m "feat(hosts): add HostProfile model and register in ModelContainer"
```

---

## Task 4: HostsWriter protocol + AppleScriptWriter

**Files:**
- Create: `Sources/AnyDoor/Services/Hosts/HostsWriter.swift`
- Test: `Tests/AnyDoorTests/HostsWriterTests.swift`

The protocol is the seam the business layer depends on. `PrivilegedHelperWriter` is implemented in Task 8 (needs the helper). `AppleScriptWriter` is the dev/ad-hoc fallback. A `MockHostsWriter` is added for tests.

- [ ] **Step 1: Write the failing test (MockHostsWriter behavior)**

`Tests/AnyDoorTests/HostsWriterTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class HostsWriterTests: XCTestCase {
    func test_mockRecordsLastWrite() async throws {
        let mock = MockHostsWriter()
        try await mock.write("hello")
        XCTAssertEqual(mock.lastWritten, "hello")
        XCTAssertEqual(mock.writeCount, 1)
    }

    func test_mockThrowsWhenConfigured() async {
        let mock = MockHostsWriter()
        mock.errorToThrow = HostsWriterError.writeFailed("boom")
        do {
            try await mock.write("x")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(mock.writeCount, 0)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter HostsWriterTests`
Expected: FAIL — types not defined.

- [ ] **Step 3: Implement protocol, error, AppleScriptWriter, and the test mock**

`Sources/AnyDoor/Services/Hosts/HostsWriter.swift`:

```swift
import Foundation

enum HostsWriterError: Error, Equatable {
    case writeFailed(String)
    case authorizationCancelled
}

/// Abstraction over the privileged write to `/etc/hosts`. Implementations:
/// `PrivilegedHelperWriter` (production, XPC), `AppleScriptWriter` (dev fallback).
protocol HostsWriter: Sendable {
    func write(_ content: String) async throws
}

/// Dev / ad-hoc fallback. Writes to an unpredictable temp file then copies it
/// over `/etc/hosts` with an administrator-authorized shell command. Never
/// changes the permissions of `/etc/hosts`.
struct AppleScriptWriter: HostsWriter {
    func write(_ content: String) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-hosts-\(UUID().uuidString)")
        try content.data(using: .utf8)?.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Quote both paths; embed via AppleScript "quoted form of".
        let script = """
        do shell script "/bin/cp " & quoted form of "\(tmp.path)" & " /etc/hosts" with administrator privileges
        """
        do {
            _ = try await AppleScriptRunner.run(script)
        } catch {
            throw HostsWriterError.writeFailed(String(describing: error))
        }
    }
}
```

`Sources/AnyDoor/Services/Hosts/MockHostsWriter.swift` (test support, but kept in the app target so tests can `@testable import`):

```swift
import Foundation

/// In-memory `HostsWriter` for unit tests. Records the last payload and can be
/// configured to throw.
final class MockHostsWriter: HostsWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastWritten: String?
    private var _writeCount = 0
    var errorToThrow: Error?

    var lastWritten: String? { lock.withLock { _lastWritten } }
    var writeCount: Int { lock.withLock { _writeCount } }

    func write(_ content: String) async throws {
        if let errorToThrow { throw errorToThrow }
        lock.withLock {
            _lastWritten = content
            _writeCount += 1
        }
    }
}
```

> Note: confirm `AppleScriptRunner.run(_:)` signature at `Sources/AnyDoor/Services/AppleScriptRunner.swift` (it returns `String` and is `async throws`). Adjust the call if the signature differs.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter HostsWriterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Hosts/HostsWriter.swift Sources/AnyDoor/Services/Hosts/MockHostsWriter.swift Tests/AnyDoorTests/HostsWriterTests.swift
git commit -m "feat(hosts): add HostsWriter protocol, AppleScript fallback, test mock"
```

---

## Task 5: HostsBackupStore (TDD)

**Files:**
- Create: `Sources/AnyDoor/Services/Hosts/HostsBackupStore.swift`
- Test: `Tests/AnyDoorTests/HostsBackupStoreTests.swift`

Backup snapshot is plain-file IO into App Support (no privilege). Restore goes through a `HostsWriter`. The store reads the live `/etc/hosts` via an injectable reader so tests don't touch the real file.

- [ ] **Step 1: Write the failing tests**

`Tests/AnyDoorTests/HostsBackupStoreTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class HostsBackupStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hosts-backup-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func test_ensureOriginalBackup_writesSnapshotOnce() throws {
        let dir = tempDir()
        var reads = 0
        let store = HostsBackupStore(backupDirectory: dir, readLiveHosts: {
            reads += 1
            return "127.0.0.1 localhost\n"
        })
        try store.ensureOriginalBackup()
        try store.ensureOriginalBackup()  // second call must be a no-op
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(store.hasBackup)
        XCTAssertEqual(store.originalContents(), "127.0.0.1 localhost\n")
    }

    func test_restoreFirstRunBackup_writesSnapshotThroughWriter() async throws {
        let dir = tempDir()
        let store = HostsBackupStore(backupDirectory: dir, readLiveHosts: { "ORIGINAL\n" })
        try store.ensureOriginalBackup()
        let mock = MockHostsWriter()
        try await store.restoreFirstRunBackup(using: mock)
        XCTAssertEqual(mock.lastWritten, "ORIGINAL\n")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter HostsBackupStoreTests`
Expected: FAIL — `HostsBackupStore` not defined.

- [ ] **Step 3: Implement HostsBackupStore**

`Sources/AnyDoor/Services/Hosts/HostsBackupStore.swift`:

```swift
import Foundation

/// One-time snapshot of the user's original `/etc/hosts`, plus restore.
/// Snapshot is stored in App Support; restore writes back through a HostsWriter.
struct HostsBackupStore {
    private let backupURL: URL
    private let readLiveHosts: () throws -> String

    init(backupDirectory: URL, readLiveHosts: @escaping () throws -> String) {
        self.backupURL = backupDirectory.appendingPathComponent("original.hosts")
        self.readLiveHosts = readLiveHosts
    }

    /// Default production location: App Support/dev.bybee.AnyDoor/hosts-backup.
    static func makeDefault() -> HostsBackupStore {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
            .appendingPathComponent("hosts-backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return HostsBackupStore(backupDirectory: dir, readLiveHosts: {
            try String(contentsOf: URL(fileURLWithPath: "/etc/hosts"), encoding: .utf8)
        })
    }

    var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    func originalContents() -> String? {
        try? String(contentsOf: backupURL, encoding: .utf8)
    }

    /// Snapshot the current `/etc/hosts` exactly once. No-op if a backup exists.
    func ensureOriginalBackup() throws {
        guard !hasBackup else { return }
        let live = try readLiveHosts()
        try live.data(using: .utf8)?.write(to: backupURL)
    }

    /// Overwrite `/etc/hosts` with the first-run snapshot (destructive; the UI
    /// must confirm before calling this).
    func restoreFirstRunBackup(using writer: HostsWriter) async throws {
        guard let original = originalContents() else {
            throw HostsWriterError.writeFailed("no backup available")
        }
        try await writer.write(original)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter HostsBackupStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Hosts/HostsBackupStore.swift Tests/AnyDoorTests/HostsBackupStoreTests.swift
git commit -m "feat(hosts): add one-time backup store with restore"
```

---

## Task 6: HostsManager (single source of truth, TDD)

**Files:**
- Create: `Sources/AnyDoor/Services/Hosts/HostsManager.swift`
- Test: `Tests/AnyDoorTests/HostsManagerTests.swift`

`HostsManager` mirrors `PanelStore` (`@MainActor @Observable`, `bootstrap(modelContainer:)`, SwiftData-backed). For testability it takes an injectable `writer` and an injectable `readLiveHosts`. The shared singleton uses production defaults; tests construct an isolated instance.

Persisted-state semantics (from the spec): editing a non-active profile saves immediately; toggling `isActive` or editing an active profile applies first and persists only on success.

- [ ] **Step 1: Write the failing tests**

`Tests/AnyDoorTests/HostsManagerTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AnyDoor

@MainActor
final class HostsManagerTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
        return try ModelContainer(for: HostProfile.self, configurations: config)
    }

    private func makeManager(writer: HostsWriter,
                             live: @escaping () -> String = { "127.0.0.1 localhost\n" }) throws
        -> (HostsManager, ModelContainer) {
        let container = try makeContainer()
        let mgr = HostsManager(writer: writer,
                               backup: HostsBackupStore(backupDirectory: FileManager.default.temporaryDirectory
                                   .appendingPathComponent(UUID().uuidString), readLiveHosts: live),
                               readLiveHosts: live)
        mgr.bootstrap(modelContainer: container)
        return (mgr, container)
    }

    func test_createProfile_persists_noSystemWrite() throws {
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock)
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        XCTAssertEqual(mgr.profiles.count, 1)
        XCTAssertEqual(mock.writeCount, 0)  // inactive => no write
    }

    func test_activateProfile_composesAndWritesActiveContent() async throws {
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock)
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev.example.com")
        let profile = mgr.profiles[0]
        await mgr.setActive(profile, true)
        XCTAssertTrue(mgr.profiles[0].isActive)
        let written = try XCTUnwrap(mock.lastWritten)
        XCTAssertTrue(written.contains("127.0.0.1 localhost"))      // prefix preserved
        XCTAssertTrue(written.contains("1.2.3.4 dev.example.com"))  // active content
        XCTAssertTrue(written.contains(HostsFile.beginMarker))
    }

    func test_writeFailure_rollsBack_persistsNothing() async throws {
        let mock = MockHostsWriter()
        let (mgr, container) = try makeManager(writer: mock)
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        mock.errorToThrow = HostsWriterError.writeFailed("denied")
        let profile = mgr.profiles[0]
        await mgr.setActive(profile, true)
        // in-memory rolled back
        XCTAssertFalse(mgr.profiles[0].isActive)
        // nothing persisted as active
        let rows = try container.mainContext.fetch(FetchDescriptor<HostProfile>())
        XCTAssertFalse(rows[0].isActive)
    }

    func test_deactivate_removesManagedBlock() async throws {
        let mock = MockHostsWriter()
        let (mgr, _) = try makeManager(writer: mock)
        mgr.createProfile(name: "Dev", content: "1.2.3.4 dev")
        let p = mgr.profiles[0]
        await mgr.setActive(p, true)
        await mgr.setActive(mgr.profiles[0], false)
        let written = try XCTUnwrap(mock.lastWritten)
        XCTAssertFalse(written.contains(HostsFile.beginMarker))
        XCTAssertTrue(written.contains("127.0.0.1 localhost"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter HostsManagerTests`
Expected: FAIL — `HostsManager` not defined.

- [ ] **Step 3: Implement HostsManager**

`Sources/AnyDoor/Services/Hosts/HostsManager.swift`:

```swift
import Foundation
import SwiftData
import OSLog
import Observation

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "hosts")

/// Single source of truth for host profiles. SwiftData-backed, @MainActor.
/// Persisted state always equals what was successfully applied to the system.
@Observable @MainActor
final class HostsManager {
    static let shared = HostsManager(
        writer: HostsManager.makeDefaultWriter(),
        backup: HostsBackupStore.makeDefault(),
        readLiveHosts: { (try? String(contentsOf: URL(fileURLWithPath: "/etc/hosts"), encoding: .utf8)) ?? "" }
    )

    private(set) var profiles: [HostProfile] = []
    /// System content (prefix + suffix) shown read-only in the UI.
    private(set) var systemHosts: String = ""
    private(set) var lastError: String?

    private let writer: HostsWriter
    private let backup: HostsBackupStore
    private let readLiveHosts: () -> String
    private var modelContainer: ModelContainer?

    init(writer: HostsWriter, backup: HostsBackupStore, readLiveHosts: @escaping () -> String) {
        self.writer = writer
        self.backup = backup
        self.readLiveHosts = readLiveHosts
    }

    /// Production writer selection: privileged helper when registered, else
    /// the AppleScript fallback (ad-hoc/dev builds).
    private static func makeDefaultWriter() -> HostsWriter {
        if HelperManager.shared.ensureRegistered() {
            return PrivilegedHelperWriter()
        }
        return AppleScriptWriter()
    }

    func bootstrap(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        reload()
    }

    func reload() {
        guard let context = modelContainer?.mainContext else { return }
        profiles = (try? context.fetch(
            FetchDescriptor<HostProfile>(sortBy: [SortDescriptor(\.displayOrder)])
        )) ?? []
        let parsed = HostsFile.parse(readLiveHosts())
        systemHosts = [parsed.prefix, parsed.suffix]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func refresh() { reload() }

    // MARK: - Mutations

    func createProfile(name: String, content: String = "") {
        guard let context = modelContainer?.mainContext else { return }
        let nextOrder = (profiles.map(\.displayOrder).max() ?? 0) + 100
        context.insert(HostProfile(name: name, content: content, displayOrder: nextOrder))
        try? context.save()
        reload()
    }

    func deleteProfile(_ profile: HostProfile) async {
        guard let context = modelContainer?.mainContext else { return }
        let wasActive = profile.isActive
        context.delete(profile)
        try? context.save()
        reload()
        if wasActive { await applyToSystem() }  // deleting an active profile re-applies
    }

    /// Edit a profile. Persists immediately; re-applies only if active.
    func updateProfile(_ profile: HostProfile, name: String, content: String) async {
        profile.name = name
        profile.content = content
        profile.updatedAt = Date()
        if profile.isActive {
            await applyAndPersist()
        } else {
            try? modelContainer?.mainContext.save()
            reload()
        }
    }

    /// Toggle activation. Applies first; persists only on success.
    func setActive(_ profile: HostProfile, _ active: Bool) async {
        let previous = profile.isActive
        profile.isActive = active
        await applyAndPersist(onFailureRollback: { profile.isActive = previous })
    }

    /// DEFAULT safe restore: remove only AnyDoor's managed block.
    func removeManagedBlock() async {
        for p in profiles { p.isActive = false }
        await applyAndPersist()
    }

    /// Destructive restore (UI must confirm): overwrite with first-run backup.
    func restoreFirstRunBackup() async {
        do {
            try await backup.restoreFirstRunBackup(using: writer)
            for p in profiles { p.isActive = false }
            try? modelContainer?.mainContext.save()
            reload()
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Apply

    private func applyAndPersist(onFailureRollback rollback: (() -> Void)? = nil) async {
        do {
            try? backup.ensureOriginalBackup()
            try await applyToSystemThrowing()
            try? modelContainer?.mainContext.save()
            lastError = nil
            reload()
        } catch {
            rollback?()
            lastError = String(describing: error)
            logger.error("Apply failed: \(error)")
            reload()
        }
    }

    /// Non-throwing convenience used by delete (state already persisted).
    private func applyToSystem() async {
        try? backup.ensureOriginalBackup()
        do { try await applyToSystemThrowing() } catch { lastError = String(describing: error) }
    }

    private func applyToSystemThrowing() async throws {
        let parsed = HostsFile.parse(readLiveHosts())
        let active = profiles
            .filter(\.isActive)
            .sorted { $0.displayOrder < $1.displayOrder }
            .map { (name: $0.name, content: $0.content) }
        let newContent = HostsFile.compose(parsed: parsed, activeProfiles: active)
        try await writer.write(newContent)
    }
}
```

> Note: `PrivilegedHelperWriter` and `HelperManager` are defined in Tasks 7-8. To keep this task self-contained and green, temporarily implement `makeDefaultWriter()` to `return AppleScriptWriter()` and add a `// TODO(Task 7): prefer PrivilegedHelperWriter` line; switch it in Task 8 Step 5. The tests inject their own writer and never call `makeDefaultWriter()`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter HostsManagerTests`
Expected: PASS (all four cases).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Hosts/HostsManager.swift Tests/AnyDoorTests/HostsManagerTests.swift
git commit -m "feat(hosts): add HostsManager with apply-then-persist semantics"
```

---

## Task 7: HelperManager (SMAppService) — SPIKE FIRST

**Files:**
- Create: `Sources/AnyDoor/Services/Hosts/HelperManager.swift`

> **SPIKE (do before writing final code):** On a signed/notarized build, verify with a throwaway minimal helper that `SMAppService.daemon(plistName:)` registers, surfaces `.requiresApproval`, and runs as root. Confirm the exact plist location in the bundle (`Contents/Library/LaunchDaemons/`), required plist keys, and the helper's embedded `Info.plist` requirements against current docs (use ctx7: query "SMAppService daemon register privileged helper"). Record findings as comments in `HelperManager.swift`. Do NOT assume legacy `SMJobBless` / `SMAuthorizedClients` semantics.

- [ ] **Step 1: Implement HelperManager covering the full status space**

`Sources/AnyDoor/Services/Hosts/HelperManager.swift`:

```swift
import Foundation
import ServiceManagement
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "hosts.helper")

/// Manages the privileged LaunchDaemon lifecycle via SMAppService.
@MainActor
final class HelperManager {
    static let shared = HelperManager()

    static let plistName = "dev.bybee.AnyDoor.HostsHelper.plist"

    enum Readiness {
        case enabled
        case requiresApproval
        case unavailable   // ad-hoc/dev build, or registration failed
    }

    private var service: SMAppService { SMAppService.daemon(plistName: Self.plistName) }

    /// True only when the daemon is registered and enabled. Used to pick the
    /// production writer; false routes to the AppleScript fallback.
    func ensureRegistered() -> Bool {
        switch readiness() {
        case .enabled:
            return true
        case .requiresApproval:
            return false
        case .unavailable:
            do {
                try service.register()
                return service.status == .enabled
            } catch {
                logger.error("Helper register failed: \(error)")
                return false
            }
        }
    }

    func readiness() -> Readiness {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .unavailable
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success. (Behavioral verification happens in the Task 14 spike on a signed build; ad-hoc builds return `.unavailable` and fall back.)

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Hosts/HelperManager.swift
git commit -m "feat(hosts): add SMAppService helper lifecycle manager"
```

---

## Task 8: Privileged helper executable + PrivilegedHelperWriter

**Files:**
- Modify: `Sources/AnyDoorHostsHelper/main.swift`
- Create: `Sources/AnyDoorHostsHelper/HostsHelperListener.swift`
- Create: `Sources/AnyDoor/Services/Hosts/PrivilegedHelperWriter.swift`
- Create: `Resources/dev.bybee.AnyDoor.HostsHelper.plist`
- Modify: `Sources/AnyDoor/Services/Hosts/HostsManager.swift` (switch default writer)

> Replace `<TEAM_ID>` below with the real Apple Developer Team ID (find via `security find-identity -v -p codesigning` — the 10-char OU in the "Developer ID Application" cert). Keep it out of commit messages.

- [ ] **Step 1: Implement the listener with caller validation, serial writes, atomic replace**

`Sources/AnyDoorHostsHelper/HostsHelperListener.swift`:

```swift
import Foundation
import HostsHelperShared
import Security

/// XPC listener delegate running as root. Validates each caller's code
/// signature before exposing the interface, serializes writes, and replaces
/// /etc/hosts atomically.
final class HostsHelperListener: NSObject, NSXPCListenerDelegate, HostsHelperProtocol, @unchecked Sendable {
    private let writeQueue = DispatchQueue(label: "dev.bybee.AnyDoor.HostsHelper.write")

    // anchor apple generic + our Team ID + our app identifier.
    private static let clientRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"<TEAM_ID>\" and identifier \"dev.bybee.AnyDoor\""

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard isValidClient(conn) else { return false }
        conn.exportedInterface = NSXPCInterface(with: HostsHelperProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }

    private func isValidClient(_ conn: NSXPCConnection) -> Bool {
        var token = conn.auditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout.size(ofValue: token))
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(Self.clientRequirement as CFString, [], &req) == errSecSuccess,
              let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    // MARK: HostsHelperProtocol

    func writeHosts(_ content: String, withReply reply: @escaping (String?) -> Void) {
        guard content.utf8.count <= HostsHelperConstants.maxPayloadBytes else {
            reply("payload too large"); return
        }
        writeQueue.async {
            do {
                try Self.atomicWrite(content)
                reply(nil)
            } catch {
                reply(String(describing: error))
            }
        }
    }

    func helperVersion(withReply reply: @escaping (String) -> Void) {
        reply(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
    }

    /// Write to a temp file in /etc (same filesystem so rename is atomic), then
    /// fsync, set root:wheel 0644, and rename over /etc/hosts.
    private static func atomicWrite(_ content: String) throws {
        let dir = "/etc"
        let template = "\(dir)/.hosts.anydoor.XXXXXX"
        var bytes = Array(template.utf8) + [0]
        let fd = bytes.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw NSError(domain: "hosts", code: Int(errno)) }
        let tmpPath = String(cString: bytes)
        defer { unlink(tmpPath) }

        let data = Array(content.utf8)
        var written = 0
        while written < data.count {
            let n = data[written...].withUnsafeBytes { write(fd, $0.baseAddress, data.count - written) }
            if n <= 0 { close(fd); throw NSError(domain: "hosts", code: Int(errno)) }
            written += n
        }
        fsync(fd)
        fchown(fd, 0, 0)            // root:wheel
        fchmod(fd, 0o644)
        close(fd)
        guard rename(tmpPath, "\(dir)/hosts") == 0 else {
            throw NSError(domain: "hosts", code: Int(errno))
        }
    }
}
```

`Sources/AnyDoorHostsHelper/main.swift`:

```swift
import Foundation
import HostsHelperShared

let delegate = HostsHelperListener()
let listener = NSXPCListener(machServiceName: HostsHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
// On-demand: launchd starts us on connect; exit when idle.
RunLoop.current.run()
```

- [ ] **Step 2: Implement PrivilegedHelperWriter (app side)**

`Sources/AnyDoor/Services/Hosts/PrivilegedHelperWriter.swift`:

```swift
import Foundation
import HostsHelperShared

/// Production writer: sends the composed hosts content to the root helper over XPC.
struct PrivilegedHelperWriter: HostsWriter {
    func write(_ content: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let conn = NSXPCConnection(machServiceName: HostsHelperConstants.machServiceName,
                                       options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: HostsHelperProtocol.self)
            conn.resume()
            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                cont.resume(throwing: HostsWriterError.writeFailed(String(describing: error)))
            } as? HostsHelperProtocol
            guard let proxy else {
                conn.invalidate()
                cont.resume(throwing: HostsWriterError.writeFailed("no proxy"))
                return
            }
            proxy.writeHosts(content) { errorMessage in
                conn.invalidate()
                if let errorMessage {
                    cont.resume(throwing: HostsWriterError.writeFailed(errorMessage))
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }
}
```

- [ ] **Step 3: Create the LaunchDaemon plist**

`Resources/dev.bybee.AnyDoor.HostsHelper.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.bybee.AnyDoor.HostsHelper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/AnyDoorHostsHelper</string>
    <key>MachServices</key>
    <dict>
        <key>dev.bybee.AnyDoor.HostsHelper</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>dev.bybee.AnyDoor</string>
    </array>
</dict>
</plist>
```

> The plist must NOT live inside the SPM `.process("Resources")` bundle (that lands in `AnyDoor_AnyDoor.bundle`, not `Contents/Library/LaunchDaemons/`). Keep this file at the repo's top-level `Resources/` and copy it explicitly in Task 13. If `Resources/` is wholly consumed by SPM resource processing for the app target, place it under a new `HelperSupport/` directory instead and update Task 13's `cp` path. Confirm against the SPIKE finding.

- [ ] **Step 4: Switch HostsManager default writer to prefer the helper**

In `Sources/AnyDoor/Services/Hosts/HostsManager.swift`, restore the real `makeDefaultWriter()` (undo the Task 6 temporary):

```swift
    private static func makeDefaultWriter() -> HostsWriter {
        if HelperManager.shared.ensureRegistered() {
            return PrivilegedHelperWriter()
        }
        return AppleScriptWriter()
    }
```

- [ ] **Step 5: Build both products**

Run: `swift build`
Run: `swift build --product AnyDoorHostsHelper`
Expected: both succeed.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoorHostsHelper Sources/AnyDoor/Services/Hosts/PrivilegedHelperWriter.swift Resources/dev.bybee.AnyDoor.HostsHelper.plist Sources/AnyDoor/Services/Hosts/HostsManager.swift
git commit -m "feat(hosts): add root helper, XPC writer, and LaunchDaemon plist"
```

---

## Task 9: BuiltinItem.hostsManager + localization

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift` (5 switch sites)
- Modify: `Sources/AnyDoor/Utilities/L10n.swift:226` (add case)
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings` (add entry)
- Test: existing `BuiltinItemLocalizationTests`, `LocalizationCoverageTests`, `BuiltinPreferenceSeederTests` must pass.

- [ ] **Step 1: Add the enum case + all five switch arms**

In `Sources/AnyDoor/Models/BuiltinItem.swift`:
- Add to the case list (after `.windowLayout`, line 49): `case hostsManager`
- `kind` (line 61): add `.hostsManager` to the `.submenu` arm → `case .appShortcuts, .portManager, .windowLayout, .hostsManager: return .submenu`
- `titleKey` (after line 123): `case .hostsManager:      return .builtinHostsManager`
- `symbol` (after line 172): `case .hostsManager: return "list.bullet.rectangle"`
- `defaultOrder` (after line 222): `case .hostsManager: return 1950`

- [ ] **Step 2: Add the L10n key (alphabetical by raw value)**

In `Sources/AnyDoor/Utilities/L10n.swift`, add near the other `builtin.*` cases (keep alphabetical; `builtin.hostsManager` sits between `builtinHideDock` line 19 and `builtinKeepAwake` line 20):

```swift
        case builtinHostsManager = "builtin.hostsManager"
```

- [ ] **Step 3: Add the translations to the string catalog**

In `Sources/AnyDoor/Resources/Localizable.xcstrings`, add a `"builtin.hostsManager"` entry mirroring the structure of the existing `"builtin.portManager"` entry, with:
- `en` value: `Hosts`
- `zh-Hans` value: `Hosts 管理`

Open the file, find the `"builtin.portManager"` block under the top-level `"strings"` object, copy its shape, and insert the new key with both `localizations`. (`LocalizationCoverageTests.test_everyL10nKeyHasZhHansAndEnTranslations` enforces both languages exist and are non-empty.)

- [ ] **Step 4: Run the localization + seeder tests**

Run: `swift test --filter BuiltinItemLocalizationTests`
Run: `swift test --filter LocalizationCoverageTests`
Run: `swift test --filter BuiltinPreferenceSeederTests`
Expected: PASS. (`testSeedsAllItemsOnEmptyStore` now expects the new count automatically via `BuiltinItem.allCases.count`.)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(hosts): register hostsManager built-in submenu with localization"
```

---

## Task 10: AppDelegate bootstrap

**Files:**
- Modify: `Sources/AnyDoor/AppDelegate.swift` (after PanelStore bootstrap, ~line 109)

- [ ] **Step 1: Bootstrap HostsManager with the shared container**

In `applicationDidFinishLaunching`, after `PanelStore.shared.bootstrap(...)` (line 109), add:

```swift
        HostsManager.shared.bootstrap(modelContainer: modelContainer)
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/AppDelegate.swift
git commit -m "feat(hosts): bootstrap HostsManager from AppDelegate"
```

---

## Task 11: Popover quick-activation UI + MenuBar wiring

**Files:**
- Create: `Sources/AnyDoor/Views/Hosts/HostsManagerPopoverView.swift`
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift:259-323` (add `.submenu(.hostsManager)` branch)

- [ ] **Step 1: Build the popover view**

`Sources/AnyDoor/Views/Hosts/HostsManagerPopoverView.swift`:

```swift
import SwiftUI

/// Hover popover for the Hosts submenu: quick activation toggles, a read-only
/// System Hosts entry with an "open file" action, and buttons to create/edit.
struct HostsManagerPopoverView: View {
    @Bindable var manager: HostsManager
    let onHoverChange: (Bool) -> Void
    let onEdit: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = manager.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            // System Hosts (read-only)
            HStack {
                Image(systemName: "cpu")
                Text("System Hosts")
                Spacer()
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/etc/hosts"))
                } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            Divider()

            ForEach(manager.profiles) { profile in
                HStack {
                    Image(systemName: profile.isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(profile.isActive ? .green : .secondary)
                    Text(profile.name)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 8).padding(.vertical, 6)
                .onTapGesture {
                    Task { await manager.setActive(profile, !profile.isActive) }
                }
            }

            Divider()
            HStack {
                Button { manager.createProfile(name: newProfileName()) } label: {
                    Label("新建", systemImage: "plus")
                }
                Spacer()
                Button { onEdit() } label: {
                    Label("编辑", systemImage: "pencil")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: 240)
        .onHover { onHoverChange($0) }
    }

    private func newProfileName() -> String {
        let base = "New Profile"
        let existing = Set(manager.profiles.map(\.name))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}
```

> UI strings here ("新建"/"编辑") should ideally be `L10n` keys for consistency. If the reviewer wants them localized, add `hostsNew` / `hostsEdit` keys following Task 9's pattern. Kept inline here to stay within the YAGNI line for v1; flag for review.

- [ ] **Step 2: Wire the popover into MenuBarView**

In `Sources/AnyDoor/Views/MenuBarView.swift`, add a new case in `mountPopoverContent(for:)` before the catch-all `case .submenu:` (currently line 321):

```swift
        case .submenu(.hostsManager):
            popover.needsKeyFocus = false
            popover.updateContent {
                HostsManagerPopoverView(
                    manager: HostsManager.shared,
                    onHoverChange: { gate.popoverHover($0) },
                    onEdit: {
                        gate.reset()
                        popover.hide()
                        HostsEditorWindowController.shared.show()
                        onRequestClose()
                    },
                    onClose: {
                        gate.reset()
                        popover.hide()
                    }
                )
            }
            Task { HostsManager.shared.refresh() }
            popover.show(anchoredTo: convertedTriggerFrame(for: target))
```

> `HostsEditorWindowController.shared.show()` is defined in Task 12. If implementing strictly task-by-task, temporarily replace the `onEdit` body with `popover.hide()` and a `// TODO(Task 12)` until Task 12 lands, then wire it.

- [ ] **Step 3: Build + run smoke check**

Run: `swift build`
Expected: success.
Run: `swift run AnyDoor` — hover the Hosts row in the menu bar; the popover lists System Hosts + profiles; toggling a profile triggers a write (in dev this prompts for admin via AppleScript fallback).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/Hosts/HostsManagerPopoverView.swift Sources/AnyDoor/Views/MenuBarView.swift
git commit -m "feat(hosts): add quick-activation popover and menu bar wiring"
```

---

## Task 12: Editor window (master-detail)

**Files:**
- Create: `Sources/AnyDoor/Views/Hosts/HostsEditorWindowController.swift`
- Create: `Sources/AnyDoor/Views/Hosts/HostsEditorView.swift`

Follow the `CommandPaletteWindowController` pattern (`Sources/AnyDoor/Views/CommandPaletteWindowController.swift:4-85`): singleton, `NSPanel`, `NSHostingView`, activate-then-key.

- [ ] **Step 1: Window controller**

`Sources/AnyDoor/Views/Hosts/HostsEditorWindowController.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class HostsEditorWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HostsEditorWindowController()

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Hosts"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        let view = HostsEditorView(manager: HostsManager.shared)
        let host = NSHostingView(rootView: view)
        host.frame = window?.contentLayoutRect ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host
        HostsManager.shared.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }
}
```

- [ ] **Step 2: Editor view (master-detail)**

`Sources/AnyDoor/Views/Hosts/HostsEditorView.swift`:

```swift
import SwiftUI

/// Master-detail editor: profile list on the left, content editor on the right.
/// System Hosts is read-only with an "open file" action.
struct HostsEditorView: View {
    @Bindable var manager: HostsManager
    @State private var selection: HostProfile.ID?
    @State private var draftName: String = ""
    @State private var draftContent: String = ""
    @State private var showRestoreConfirm = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("System Hosts", systemImage: "cpu").tag(Optional<HostProfile.ID>.none)
                }
                Section {
                    ForEach(manager.profiles) { profile in
                        HStack {
                            Image(systemName: profile.isActive ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(profile.isActive ? .green : .secondary)
                                .onTapGesture { Task { await manager.setActive(profile, !profile.isActive) } }
                            Text(profile.name)
                        }
                        .tag(Optional(profile.id))
                    }
                }
            }
            .frame(minWidth: 220)
            .toolbar {
                ToolbarItem {
                    Button { manager.createProfile(name: "New Profile") } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem {
                    Button { deleteSelected() } label: { Image(systemName: "trash") }
                        .disabled(selectedProfile == nil)
                }
            }
        } detail: {
            detail
        }
        .onChange(of: selection) { _, _ in loadDraft() }
    }

    @ViewBuilder
    private var detail: some View {
        if let profile = selectedProfile {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $draftContent)
                    .font(.system(.body, design: .monospaced))
                    .border(.quaternary)
                HStack {
                    Button("保存") {
                        Task { await manager.updateProfile(profile, name: draftName, content: draftContent) }
                    }
                    Spacer()
                    Button("移除托管块") { Task { await manager.removeManagedBlock() } }
                    Button("恢复首次备份") { showRestoreConfirm = true }
                }
            }
            .padding()
            .confirmationDialog("覆盖 /etc/hosts 为首次备份？外部改动将丢失。",
                                isPresented: $showRestoreConfirm, titleVisibility: .visible) {
                Button("恢复", role: .destructive) { Task { await manager.restoreFirstRunBackup() } }
                Button("取消", role: .cancel) {}
            }
        } else {
            VStack(alignment: .leading) {
                Text(manager.systemHosts)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button("用默认编辑器打开") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/etc/hosts"))
                }
            }
            .padding()
        }
    }

    private var selectedProfile: HostProfile? {
        guard let selection else { return nil }
        return manager.profiles.first { $0.id == selection }
    }

    private func loadDraft() {
        draftName = selectedProfile?.name ?? ""
        draftContent = selectedProfile?.content ?? ""
    }

    private func deleteSelected() {
        guard let profile = selectedProfile else { return }
        Task { await manager.deleteProfile(profile) }
        selection = nil
    }
}
```

> UI strings are inline Chinese for v1 (consistent with this file's scope). Flag for the reviewer if full `L10n` coverage is required; if so, add keys per Task 9.

- [ ] **Step 3: Build + smoke check**

Run: `swift build`
Run: `swift run AnyDoor` — open the editor from the popover "编辑"; create a profile, type content, save, activate; confirm `/etc/hosts` updates (admin prompt in dev). Select System Hosts → read-only + open button.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/Hosts/HostsEditorWindowController.swift Sources/AnyDoor/Views/Hosts/HostsEditorView.swift
git commit -m "feat(hosts): add master-detail editor window"
```

---

## Task 13: Build/sign the helper in release.sh + Makefile

**Files:**
- Modify: `scripts/release.sh` (Task 4 build ~line 137, Task 5 assemble ~line 148, Task 6 codesign ~line 199)
- Modify: `Makefile:19-42` (install target — copy helper for local signed-ish installs; ad-hoc still falls back)

- [ ] **Step 1: Build the helper universal in release.sh**

After `swift build -c release "${BUILD_FLAGS[@]}"` (line 137) the helper is already built as part of the package. In the assemble section (after copying the main binary, ~line 148), add:

```bash
cp "$BIN_PATH/AnyDoorHostsHelper" "$APP/Contents/MacOS/AnyDoorHostsHelper"
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp Resources/dev.bybee.AnyDoor.HostsHelper.plist "$APP/Contents/Library/LaunchDaemons/"
```

> If the plist had to move out of `Resources/` in Task 8 Step 3, update the `cp` source path accordingly.

- [ ] **Step 2: Sign the helper depth-first (before the main binary)**

In the codesign section, add this line BEFORE the `codesign ... "$APP/Contents/MacOS/AnyDoor"` line (line 199):

```bash
codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/AnyDoorHostsHelper"
```

- [ ] **Step 3: Update Makefile install for local testing**

In `Makefile` `install:` target, after copying the main binary (line 23), add:

```makefile
	@cp .build/release/AnyDoorHostsHelper $(APP_DIR)/Contents/MacOS/ 2>/dev/null || true
	@mkdir -p $(APP_DIR)/Contents/Library/LaunchDaemons
	@cp Resources/dev.bybee.AnyDoor.HostsHelper.plist $(APP_DIR)/Contents/Library/LaunchDaemons/
```

> `make install` uses ad-hoc signing, so SMAppService won't register; the app falls back to AppleScript. The helper files are staged so a later properly-signed build is one step away.

- [ ] **Step 4: Dry-run the release packaging path (no publish)**

Run: `DRYRUN=1 ./scripts/release.sh 0.0.0-helpertest` in a clean tree on a branch (or visually inspect the diff if a full signed build isn't available). Expected: assemble + codesign steps reference the helper without error. Revert any version/CHANGELOG churn the dry run caused.

- [ ] **Step 5: Commit**

```bash
git add scripts/release.sh Makefile
git commit -m "build(hosts): bundle and codesign the privileged helper"
```

---

## Task 14: End-to-end spike verification (signed build, manual)

**Files:** none (verification + notes).

- [ ] **Step 1: Produce a signed, notarized build** via the normal release path (or a signing-only variant) so `SMAppService` can register.

- [ ] **Step 2: Verify registration + approval flow**
  - Launch the app; trigger a hosts activation.
  - Confirm the system prompts once (Login Items & Extensions) and `HelperManager.readiness()` resolves to `.enabled` after approval.

- [ ] **Step 3: Verify privileged write**
  - Activate a profile; confirm `/etc/hosts` gains the managed block, ownership stays `root:wheel`, mode `0644`, and the system prefix/suffix are untouched.
  - Manually append a line after the managed block, toggle a profile, and confirm the appended suffix survives (suffix preservation in production).

- [ ] **Step 4: Verify caller validation**
  - Confirm an unsigned/other-team process cannot connect (the listener rejects it). Record the test method used.

- [ ] **Step 5: Record findings** in `docs/superpowers/specs/2026-06-03-hosts-editing-design.md` under a new "Spike Results" section, and fix any code that diverged from the spike reality (especially plist keys / client-auth mechanism). Commit:

```bash
git add docs/superpowers/specs/2026-06-03-hosts-editing-design.md
git commit -m "docs(hosts): record helper registration + signing spike results"
```

---

## Self-Review (completed by plan author)

**Spec coverage:** profiles CRUD (Tasks 3, 6, 11, 12) · multi-active merge (Tasks 2, 6) · system content untouched incl. suffix (Task 2 + tests) · privileged helper SMAppService (Tasks 7, 8, 14) · dev fallback (Task 4, 6) · backup + two-mode restore (Tasks 5, 6, 12) · popover + editor (Tasks 11, 12) · panel integration + L10n (Tasks 9, 10) · helper security boundary (Task 8) · atomic write (Task 8) · apply-then-persist (Task 6) · universal build + depth-first sign (Task 13) · full SMAppService status space (Task 7) · tests incl. suffix/marker-injection/rollback/idempotency (Tasks 2, 6). All spec sections map to a task.

**Placeholder scan:** The only deferred items are the cross-task forward references (Task 6→7/8 default-writer; Task 11→12 window controller), each given an explicit temporary-then-switch instruction. No "TBD"/"add error handling"-style gaps.

**Type consistency:** `HostsWriter.write(_:)`, `HostsManager.setActive(_:_:)`/`createProfile`/`updateProfile`/`removeManagedBlock`/`restoreFirstRunBackup`, `HostsFile.parse`/`compose`/`beginMarker`/`endMarker`/`Parsed`, `HostsBackupStore.ensureOriginalBackup`/`restoreFirstRunBackup(using:)`, `HelperManager.ensureRegistered`/`readiness`, `HostsHelperConstants.machServiceName`/`maxPayloadBytes`, and `HostsHelperProtocol.writeHosts(_:withReply:)` are used consistently across tasks.
