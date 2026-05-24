# Generated Clipboard History Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 7-day local history for AnyDoor-generated OCR text, color picks, QR payloads, and screenshots, shown from hover popovers on the existing action rows.

**Architecture:** Add a focused SwiftData model plus an independent `ClipboardHistoryStore` that owns history persistence, screenshot files, pruning, cache reloads, and pasteboard copy-back. Keep the four existing panel rows as `.action`; generalize `MenuBarView` hover state from submenu-only to typed popover targets so history popovers can mount without changing click or hotkey behavior.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, AppKit `NSPasteboard`, ImageIO/AppKit image encoding, existing `HoverPopover` / `HoverGate`, existing `ToastPresenter`.

---

## File Structure

Create:

- `Sources/AnyDoor/Models/ClipboardHistoryItem.swift`
  SwiftData model plus `ClipboardHistoryKind` enum and display metadata helpers.

- `Sources/AnyDoor/Services/ClipboardHistoryStore.swift`
  MainActor observable store. Owns SwiftData access, in-memory cache, PNG file storage, pruning, copy-back, and clear-all.

- `Sources/AnyDoor/Views/ClipboardHistorySelectionModel.swift`
  Small testable state machine for selected row, arrow movement, preview toggling, and copy intent.

- `Sources/AnyDoor/Views/ClipboardHistoryPopoverView.swift`
  SwiftUI side popover for one history kind. Renders rows, previews, keyboard monitor, and copy/close callbacks.

- `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`
  Store/model/prune/file/pasteboard tests.

- `Tests/AnyDoorTests/ClipboardHistorySelectionModelTests.swift`
  Keyboard and hover selection behavior tests.

Modify:

- `Sources/AnyDoor/AppDelegate.swift`
  Add `ClipboardHistoryItem` to the `ModelContainer` schema and bootstrap/prune `ClipboardHistoryStore`.

- `Sources/AnyDoor/Models/BuiltinItem.swift`
  Add `historyKind` mapping for OCR, color, QR, and screenshot.

- `Sources/AnyDoor/Services/Providers/OCRProvider.swift`
  Record OCR text after successful pasteboard write.

- `Sources/AnyDoor/Services/Providers/QRCodeProvider.swift`
  Record QR payload text after successful pasteboard write.

- `Sources/AnyDoor/Services/Providers/PickColorProvider.swift`
  Record HEX color after successful pasteboard write.

- `Sources/AnyDoor/Services/Providers/ScreenshotProvider.swift`
  Immediately record screenshot image from pasteboard after successful `screencapture -i -c`.

- `Sources/AnyDoor/Views/MenuBarView.swift`
  Replace submenu-only hover state with typed hover targets and mount history popovers.

- `Sources/AnyDoor/Views/GeneralSettingsView.swift`
  Add a destructive clear history button.

- `Tests/AnyDoorTests/MigrationTests.swift`
  Add model metadata and `BuiltinItem.historyKind` assertions.

- `Tests/AnyDoorTests/PanelStoreTests.swift` or a new focused test if cleaner
  Assert history-capable built-ins remain actions and hotkey snapshots still include action hotkeys.

---

## Chunk 1: Model And Store Foundation

### Task 1: Add Clipboard History Model

**Files:**
- Create: `Sources/AnyDoor/Models/ClipboardHistoryItem.swift`
- Modify: `Tests/AnyDoorTests/MigrationTests.swift`

- [ ] **Step 1: Write failing model tests**

Append to `Tests/AnyDoorTests/MigrationTests.swift` or create a focused model test section in `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`:

```swift
final class ClipboardHistoryItemModelTests: XCTestCase {
    func testClipboardHistoryKindMetadata() {
        XCTAssertEqual(ClipboardHistoryKind.ocr.title, "屏幕取词")
        XCTAssertEqual(ClipboardHistoryKind.color.title, "屏幕取色")
        XCTAssertEqual(ClipboardHistoryKind.qrcode.title, "识别二维码")
        XCTAssertEqual(ClipboardHistoryKind.screenshot.title, "截图")
    }

    func testClipboardHistoryItemCanBePersisted() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipboardHistoryItem.self, configurations: config)
        let context = ModelContext(container)

        let item = ClipboardHistoryItem(
            kind: .ocr,
            text: "hello",
            fileName: nil,
            colorHex: nil,
            previewTitle: "hello",
            previewSubtitle: "5 字符",
            createdAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        context.insert(item)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<ClipboardHistoryItem>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, ClipboardHistoryKind.ocr.rawValue)
        XCTAssertEqual(rows[0].text, "hello")
        XCTAssertNil(rows[0].colorHex)
    }
}
```

- [ ] **Step 2: Run model tests to verify they fail**

Run:

```bash
swift test --filter ClipboardHistoryItemModelTests
```

Expected: compile fails because `ClipboardHistoryItem` and `ClipboardHistoryKind` do not exist.

- [ ] **Step 3: Implement model**

Create `Sources/AnyDoor/Models/ClipboardHistoryItem.swift`:

```swift
import Foundation
import SwiftData

enum ClipboardHistoryKind: String, CaseIterable, Sendable {
    case ocr
    case color
    case qrcode
    case screenshot

    var title: String {
        switch self {
        case .ocr: return "屏幕取词"
        case .color: return "屏幕取色"
        case .qrcode: return "识别二维码"
        case .screenshot: return "截图"
        }
    }
}

@Model
final class ClipboardHistoryItem {
    @Attribute(.unique) var id: UUID
    var kind: String
    var text: String?
    var fileName: String?
    var colorHex: String?
    var previewTitle: String
    var previewSubtitle: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        kind: ClipboardHistoryKind,
        text: String? = nil,
        fileName: String? = nil,
        colorHex: String? = nil,
        previewTitle: String,
        previewSubtitle: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind.rawValue
        self.text = text
        self.fileName = fileName
        self.colorHex = colorHex
        self.previewTitle = previewTitle
        self.previewSubtitle = previewSubtitle
        self.createdAt = createdAt
    }

    @Transient var historyKind: ClipboardHistoryKind? {
        ClipboardHistoryKind(rawValue: kind)
    }
}
```

- [ ] **Step 4: Run model tests to verify they pass**

Run:

```bash
swift test --filter ClipboardHistoryItemModelTests
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/ClipboardHistoryItem.swift Tests/AnyDoorTests/MigrationTests.swift
git commit -m "feat(history): add generated clipboard history model"
```

### Task 2: Build ClipboardHistoryStore Text, Color, Cache, And Pruning

**Files:**
- Create: `Sources/AnyDoor/Services/ClipboardHistoryStore.swift`
- Create: `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`

- [ ] **Step 1: Write failing store tests for text/color/cache/prune**

Create `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`:

```swift
import AppKit
import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardHistoryStoreTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: ClipboardHistoryItem.self, configurations: config)
    }

    func testRecordTextReloadsNewestFirstForKindOnly() async throws {
        let container = try makeContainer()
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let store = ClipboardHistoryStore(now: { now })
        store.bootstrap(modelContainer: container)

        await store.recordText(kind: .ocr, text: "first")
        now = Date(timeIntervalSinceReferenceDate: 200)
        await store.recordText(kind: .qrcode, text: "qr")
        now = Date(timeIntervalSinceReferenceDate: 300)
        await store.recordText(kind: .ocr, text: "second\nline")

        await store.reload(kind: .ocr)
        XCTAssertEqual(store.items(for: .ocr).map(\.text), ["second\nline", "first"])
        XCTAssertEqual(store.items(for: .ocr).first?.previewTitle, "second")
    }

    func testRecordColorStoresColorHexAndNoText() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)

        await store.recordColor(hex: "#ffcc00")
        await store.reload(kind: .color)

        let item = try XCTUnwrap(store.items(for: .color).first)
        XCTAssertEqual(item.colorHex, "#FFCC00")
        XCTAssertNil(item.text)
        XCTAssertEqual(item.previewTitle, "#FFCC00")
    }

    func testPruneDeletesExpiredAndOverflowRows() async throws {
        let container = try makeContainer()
        let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now }, maxItemsPerKind: 3)
        store.bootstrap(modelContainer: container)

        let context = container.mainContext
        context.insert(ClipboardHistoryItem(kind: .ocr, text: "expired", previewTitle: "expired", createdAt: now.addingTimeInterval(-8 * 86_400)))
        for index in 0..<5 {
            context.insert(ClipboardHistoryItem(kind: .ocr, text: "\(index)", previewTitle: "\(index)", createdAt: now.addingTimeInterval(TimeInterval(index))))
        }
        try context.save()

        await store.pruneExpiredAndOverflow(force: true)
        await store.reload(kind: .ocr)

        XCTAssertEqual(store.items(for: .ocr).map(\.text), ["4", "3", "2"])
    }

    func testNonForcedPruneIsThrottled() async throws {
        let container = try makeContainer()
        var now = Date(timeIntervalSinceReferenceDate: 10_000_000)
        let store = ClipboardHistoryStore(now: { now }, pruneThrottle: 60)
        store.bootstrap(modelContainer: container)

        let context = container.mainContext
        context.insert(ClipboardHistoryItem(kind: .ocr, text: "expired", previewTitle: "expired", createdAt: now.addingTimeInterval(-8 * 86_400)))
        try context.save()

        await store.pruneExpiredAndOverflow(force: false)
        now = now.addingTimeInterval(10)
        context.insert(ClipboardHistoryItem(kind: .ocr, text: "expired2", previewTitle: "expired2", createdAt: now.addingTimeInterval(-8 * 86_400)))
        try context.save()
        await store.pruneExpiredAndOverflow(force: false)

        let rows = try context.fetch(FetchDescriptor<ClipboardHistoryItem>())
        XCTAssertTrue(rows.contains { $0.text == "expired2" })
    }
}
```

- [ ] **Step 2: Run store tests to verify they fail**

Run:

```bash
swift test --filter ClipboardHistoryStoreTests
```

Expected: compile fails because `ClipboardHistoryStore` does not exist.

- [ ] **Step 3: Implement store text/color/cache/prune**

Create `Sources/AnyDoor/Services/ClipboardHistoryStore.swift` with this shape:

```swift
import AppKit
import Foundation
import ImageIO
import OSLog
import SwiftData
import SwiftUI

private let historyLogger = Logger(subsystem: "dev.bybee.AnyDoor", category: "clipboard-history")

enum ClipboardHistoryError: Error, Sendable {
    case modelContainerUnavailable
    case missingText
    case missingColor
    case missingScreenshotFile
    case pasteboardImageUnavailable
    case pngEncodingFailed
}

@MainActor
@Observable
final class ClipboardHistoryStore {
    static let shared = ClipboardHistoryStore()

    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let maxAge: TimeInterval
    @ObservationIgnored private let maxItemsPerKind: Int
    @ObservationIgnored private let pruneThrottle: TimeInterval
    @ObservationIgnored private var lastPrunedAt: Date?

    private var cachedItems: [ClipboardHistoryKind: [ClipboardHistoryItem]] = [:]

    init(
        now: @escaping () -> Date = Date.init,
        maxAge: TimeInterval = 7 * 86_400,
        maxItemsPerKind: Int = 100,
        pruneThrottle: TimeInterval = 60
    ) {
        self.now = now
        self.maxAge = maxAge
        self.maxItemsPerKind = maxItemsPerKind
        self.pruneThrottle = pruneThrottle
    }

    func bootstrap(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func recordText(kind: ClipboardHistoryKind, text: String) async {
        guard kind == .ocr || kind == .qrcode else { return }
        guard let container = modelContainer else { return }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        let item = ClipboardHistoryItem(
            kind: kind,
            text: text,
            previewTitle: Self.previewTitle(for: text),
            previewSubtitle: Self.textSubtitle(for: text),
            createdAt: now()
        )
        container.mainContext.insert(item)
        do {
            try container.mainContext.save()
            await pruneExpiredAndOverflow(force: true)
            await reload(kind: kind)
        } catch {
            historyLogger.error("Failed to record text history: \(error)")
        }
    }

    func recordColor(hex: String) async {
        guard let container = modelContainer else { return }
        let normalized = hex.uppercased()
        guard normalized.hasPrefix("#") else { return }

        let item = ClipboardHistoryItem(
            kind: .color,
            text: nil,
            colorHex: normalized,
            previewTitle: normalized,
            previewSubtitle: nil,
            createdAt: now()
        )
        container.mainContext.insert(item)
        do {
            try container.mainContext.save()
            await pruneExpiredAndOverflow(force: true)
            await reload(kind: .color)
        } catch {
            historyLogger.error("Failed to record color history: \(error)")
        }
    }

    func reload(kind: ClipboardHistoryKind) async {
        guard let container = modelContainer else {
            cachedItems[kind] = []
            return
        }
        let rawKind = kind.rawValue
        let cutoff = now().addingTimeInterval(-maxAge)
        let descriptor = FetchDescriptor<ClipboardHistoryItem>(
            predicate: #Predicate { item in
                item.kind == rawKind && item.createdAt >= cutoff
            },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        cachedItems[kind] = (try? container.mainContext.fetch(descriptor)) ?? []
    }

    func items(for kind: ClipboardHistoryKind) -> [ClipboardHistoryItem] {
        cachedItems[kind] ?? []
    }

    func pruneExpiredAndOverflow(force: Bool) async {
        guard let container = modelContainer else { return }
        let current = now()
        if !force, let lastPrunedAt, current.timeIntervalSince(lastPrunedAt) < pruneThrottle {
            return
        }
        lastPrunedAt = current

        do {
            let context = container.mainContext
            let all = try context.fetch(FetchDescriptor<ClipboardHistoryItem>())
            let cutoff = current.addingTimeInterval(-maxAge)
            var idsToDelete = Set<UUID>()

            for item in all where item.createdAt < cutoff {
                idsToDelete.insert(item.id)
            }

            for kind in ClipboardHistoryKind.allCases {
                let rows = all
                    .filter { $0.kind == kind.rawValue && !idsToDelete.contains($0.id) }
                    .sorted { $0.createdAt > $1.createdAt }
                for item in rows.dropFirst(maxItemsPerKind) {
                    idsToDelete.insert(item.id)
                }
            }

            for item in all where idsToDelete.contains(item.id) {
                context.delete(item)
            }
            if !idsToDelete.isEmpty { try context.save() }
        } catch {
            historyLogger.error("Failed to prune clipboard history: \(error)")
        }
    }

    private static func previewTitle(for text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    private static func textSubtitle(for text: String) -> String? {
        let lineCount = text.split(whereSeparator: \.isNewline).count
        return lineCount > 1 ? "\(lineCount) 行" : "\(text.count) 字符"
    }

}
```

Task 3 adds screenshot file deletion to the prune loop. Do not add an empty helper in this task.

- [ ] **Step 4: Run store tests**

Run:

```bash
swift test --filter ClipboardHistoryStoreTests
```

Expected: text/color/cache/prune tests pass. Screenshot tests are not written yet.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardHistoryStore.swift Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift
git commit -m "feat(history): add generated clipboard history store"
```

### Task 3: Add Screenshot File Storage And Pasteboard Copy-Back

**Files:**
- Modify: `Sources/AnyDoor/Services/ClipboardHistoryStore.swift`
- Modify: `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`

- [ ] **Step 1: Add failing screenshot and pasteboard tests**

Append tests:

```swift
func testRecordScreenshotStoresPngFileAndMetadata() async throws {
    let container = try makeContainer()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ClipboardHistoryStore(
        now: { Date(timeIntervalSinceReferenceDate: 100) },
        historyDirectory: directory
    )
    store.bootstrap(modelContainer: container)

    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.lockFocus()
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 4).fill()
    image.unlockFocus()

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.writeObjects([image]))

    await store.recordScreenshotFromPasteboard()
    await store.reload(kind: .screenshot)

    let item = try XCTUnwrap(store.items(for: .screenshot).first)
    let fileName = try XCTUnwrap(item.fileName)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path))
    XCTAssertEqual(item.previewTitle, "截图")

    try? FileManager.default.removeItem(at: directory)
}

func testCopyTextAndColorBackToPasteboard() async throws {
    let container = try makeContainer()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ClipboardHistoryStore(historyDirectory: directory)
    store.bootstrap(modelContainer: container)

    let textItem = ClipboardHistoryItem(kind: .ocr, text: "hello", previewTitle: "hello")
    try await store.copyToPasteboard(textItem)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello")

    let colorItem = ClipboardHistoryItem(kind: .color, colorHex: "#FFCC00", previewTitle: "#FFCC00")
    try await store.copyToPasteboard(colorItem)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "#FFCC00")

    try? FileManager.default.removeItem(at: directory)
}

func testClearAllDeletesRowsAndScreenshotFiles() async throws {
    let container = try makeContainer()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ClipboardHistoryStore(historyDirectory: directory)
    store.bootstrap(modelContainer: container)

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("shot.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: fileURL)

    let context = container.mainContext
    context.insert(ClipboardHistoryItem(kind: .screenshot, fileName: "shot.png", previewTitle: "截图"))
    try context.save()

    await store.clearAll()

    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertTrue(try context.fetch(FetchDescriptor<ClipboardHistoryItem>()).isEmpty)
    try? FileManager.default.removeItem(at: directory)
}
```

- [ ] **Step 2: Run tests to verify failures**

Run:

```bash
swift test --filter ClipboardHistoryStoreTests
```

Expected: compile or assertion failures for missing screenshot/file/copy APIs.

- [ ] **Step 3: Implement screenshot/file APIs**

Extend `ClipboardHistoryStore` with:

```swift
@ObservationIgnored private let historyDirectoryProvider: () -> URL

convenience init(
    now: @escaping () -> Date = Date.init,
    maxAge: TimeInterval = 7 * 86_400,
    maxItemsPerKind: Int = 100,
    pruneThrottle: TimeInterval = 60,
    historyDirectory: URL
) {
    self.init(
        now: now,
        maxAge: maxAge,
        maxItemsPerKind: maxItemsPerKind,
        pruneThrottle: pruneThrottle,
        historyDirectoryProvider: { historyDirectory }
    )
}

init(
    now: @escaping () -> Date = Date.init,
    maxAge: TimeInterval = 7 * 86_400,
    maxItemsPerKind: Int = 100,
    pruneThrottle: TimeInterval = 60,
    historyDirectoryProvider: @escaping () -> URL = ClipboardHistoryStore.defaultHistoryDirectory
) {
    self.now = now
    self.maxAge = maxAge
    self.maxItemsPerKind = maxItemsPerKind
    self.pruneThrottle = pruneThrottle
    self.historyDirectoryProvider = historyDirectoryProvider
}

static func defaultHistoryDirectory() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport
        .appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
        .appendingPathComponent("ClipboardHistory", isDirectory: true)
}
```

Add:

```swift
func recordScreenshotFromPasteboard() async {
    guard let container = modelContainer else { return }
    do {
        let png = try Self.pngDataFromPasteboard(NSPasteboard.general)
        let id = UUID()
        let directory = historyDirectoryProvider()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(id.uuidString).png"
        try png.write(to: directory.appendingPathComponent(fileName), options: .atomic)

        let item = ClipboardHistoryItem(
            id: id,
            kind: .screenshot,
            fileName: fileName,
            previewTitle: "截图",
            previewSubtitle: nil,
            createdAt: now()
        )
        container.mainContext.insert(item)
        try container.mainContext.save()
        await pruneExpiredAndOverflow(force: true)
        await reload(kind: .screenshot)
    } catch {
        historyLogger.error("Failed to record screenshot history: \(error)")
    }
}

func copyToPasteboard(_ item: ClipboardHistoryItem) async throws {
    guard let kind = item.historyKind else { throw ClipboardHistoryError.missingText }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()

    switch kind {
    case .ocr, .qrcode:
        guard let text = item.text else { throw ClipboardHistoryError.missingText }
        pasteboard.setString(text, forType: .string)
    case .color:
        guard let hex = item.colorHex else { throw ClipboardHistoryError.missingColor }
        pasteboard.setString(hex, forType: .string)
    case .screenshot:
        guard let fileName = item.fileName else { throw ClipboardHistoryError.missingScreenshotFile }
        let url = historyDirectoryProvider().appendingPathComponent(fileName)
        guard let image = NSImage(contentsOf: url) else { throw ClipboardHistoryError.missingScreenshotFile }
        pasteboard.writeObjects([image])
    }
}
```

Implement `pngDataFromPasteboard` using `NSImage` and `CGImageDestination` or `NSBitmapImageRep.representation(using: .png, properties: [:])`. Prefer AppKit APIs already present in the project, no new dependency.

Finish:

- `deleteScreenshotFileIfNeeded(for:)`
- orphan PNG cleanup inside `pruneExpiredAndOverflow(force:)`
- `clearAll()`

- [ ] **Step 4: Run screenshot/file tests**

Run:

```bash
swift test --filter ClipboardHistoryStoreTests
```

Expected: all store tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardHistoryStore.swift Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift
git commit -m "feat(history): store screenshot history files"
```

---

## Chunk 2: Provider And Built-In Integration

### Task 4: Add BuiltinItem History Mapping

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift`
- Modify: `Tests/AnyDoorTests/MigrationTests.swift`

- [ ] **Step 1: Write failing built-in metadata tests**

Append to `BuiltinItemTests`:

```swift
func testHistoryKinds() {
    XCTAssertEqual(BuiltinItem.ocr.historyKind, .ocr)
    XCTAssertEqual(BuiltinItem.pickColor.historyKind, .color)
    XCTAssertEqual(BuiltinItem.qrcode.historyKind, .qrcode)
    XCTAssertEqual(BuiltinItem.screenshot.historyKind, .screenshot)
    XCTAssertNil(BuiltinItem.keepAwake.historyKind)
    XCTAssertNil(BuiltinItem.portManager.historyKind)
}

func testHistoryCapableItemsRemainActions() {
    XCTAssertEqual(BuiltinItem.ocr.kind, .action)
    XCTAssertEqual(BuiltinItem.pickColor.kind, .action)
    XCTAssertEqual(BuiltinItem.qrcode.kind, .action)
    XCTAssertEqual(BuiltinItem.screenshot.kind, .action)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter BuiltinItemTests
```

Expected: compile fails because `historyKind` does not exist.

- [ ] **Step 3: Implement `historyKind`**

Add to `BuiltinItem.swift`:

```swift
var historyKind: ClipboardHistoryKind? {
    switch self {
    case .ocr: return .ocr
    case .pickColor: return .color
    case .qrcode: return .qrcode
    case .screenshot: return .screenshot
    default: return nil
    }
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
swift test --filter BuiltinItemTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift Tests/AnyDoorTests/MigrationTests.swift
git commit -m "feat(history): map built-ins to generated history kinds"
```

### Task 5: Bootstrap Store And Model Container

**Files:**
- Modify: `Sources/AnyDoor/AppDelegate.swift`
- Modify: `Tests/AnyDoorTests/PanelStoreTests.swift`
- Modify: any test helper containers that use only `KeyBinding.self, BuiltinPreference.self` when they now need history.

- [ ] **Step 1: Add compile-facing schema checks**

Search:

```bash
rg "ModelContainer\\(" Tests Sources/AnyDoor -n
```

Update only containers that need app-equivalent schemas. Tests that intentionally isolate one model can stay isolated.

- [ ] **Step 2: Modify AppDelegate container**

Change:

```swift
modelContainer = try ModelContainer(
    for: KeyBinding.self, BuiltinPreference.self,
    configurations: config
)
```

to:

```swift
modelContainer = try ModelContainer(
    for: KeyBinding.self, BuiltinPreference.self, ClipboardHistoryItem.self,
    configurations: config
)
```

In `applicationDidFinishLaunching`, after seeding and before providers can record history:

```swift
ClipboardHistoryStore.shared.bootstrap(modelContainer: modelContainer)
Task { await ClipboardHistoryStore.shared.pruneExpiredAndOverflow(force: true) }
```

- [ ] **Step 3: Run build**

Run:

```bash
make build
```

Expected: build passes.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/AppDelegate.swift Tests/AnyDoorTests/PanelStoreTests.swift Tests/AnyDoorTests/MigrationTests.swift
git commit -m "feat(history): bootstrap generated clipboard history store"
```

### Task 6: Record Provider Outputs

**Files:**
- Modify: `Sources/AnyDoor/Services/Providers/OCRProvider.swift`
- Modify: `Sources/AnyDoor/Services/Providers/QRCodeProvider.swift`
- Modify: `Sources/AnyDoor/Services/Providers/PickColorProvider.swift`
- Modify: `Sources/AnyDoor/Services/Providers/ScreenshotProvider.swift`

- [ ] **Step 1: Wire OCR recording**

After OCR writes text to pasteboard and before or after success toast:

```swift
await ClipboardHistoryStore.shared.recordText(kind: .ocr, text: text)
```

Keep existing cancellation and error behavior unchanged.

- [ ] **Step 2: Wire QR recording**

After QR writes text to pasteboard:

```swift
await ClipboardHistoryStore.shared.recordText(kind: .qrcode, text: text)
```

Do not put payload into toast.

- [ ] **Step 3: Wire color recording**

After color writes HEX to pasteboard:

```swift
await ClipboardHistoryStore.shared.recordColor(hex: hex)
```

- [ ] **Step 4: Wire screenshot recording in same await chain**

Change `ScreenshotProvider.run()` to:

```swift
func run() async throws {
    do {
        _ = try await ShellRunner.run("/usr/sbin/screencapture", args: ["-i", "-c"], timeout: nil)
        await ClipboardHistoryStore.shared.recordScreenshotFromPasteboard()
    } catch BuiltinError.shellFailed {
        // screencapture exits non-zero when the user cancels with Esc; treat cancellation as a no-op.
    }
}
```

Do not wrap the store call in a detached `Task`. The pasteboard read must happen immediately after `screencapture` returns.

- [ ] **Step 5: Run provider compile check**

Run:

```bash
make build
```

Expected: build passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/OCRProvider.swift Sources/AnyDoor/Services/Providers/QRCodeProvider.swift Sources/AnyDoor/Services/Providers/PickColorProvider.swift Sources/AnyDoor/Services/Providers/ScreenshotProvider.swift
git commit -m "feat(history): record generated clipboard outputs"
```

---

## Chunk 3: History Popover And Hover State

### Task 7: Add Selection Model

**Files:**
- Create: `Sources/AnyDoor/Views/ClipboardHistorySelectionModel.swift`
- Create: `Tests/AnyDoorTests/ClipboardHistorySelectionModelTests.swift`

- [ ] **Step 1: Write failing selection model tests**

```swift
import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardHistorySelectionModelTests: XCTestCase {
    func testInitialSelectionUsesFirstItem() {
        let ids = [UUID(), UUID()]
        let model = ClipboardHistorySelectionModel()
        model.replaceItems(ids)
        XCTAssertEqual(model.selectedID, ids[0])
    }

    func testMoveSelectionClamps() {
        let ids = [UUID(), UUID(), UUID()]
        let model = ClipboardHistorySelectionModel()
        model.replaceItems(ids)
        model.moveDown()
        model.moveDown()
        model.moveDown()
        XCTAssertEqual(model.selectedID, ids[2])
        model.moveUp()
        XCTAssertEqual(model.selectedID, ids[1])
    }

    func testHoverSelectsItemAndSpaceTogglesPreview() {
        let id = UUID()
        let model = ClipboardHistorySelectionModel()
        model.replaceItems([id])
        model.select(id)
        XCTAssertEqual(model.selectedID, id)
        model.togglePreview()
        XCTAssertEqual(model.previewedID, id)
        model.togglePreview()
        XCTAssertNil(model.previewedID)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
swift test --filter ClipboardHistorySelectionModelTests
```

Expected: compile fails because model does not exist.

- [ ] **Step 3: Implement selection model**

Create:

```swift
import Foundation
import Observation

@MainActor
@Observable
final class ClipboardHistorySelectionModel {
    private var orderedIDs: [UUID] = []
    private(set) var selectedID: UUID?
    private(set) var previewedID: UUID?

    func replaceItems(_ ids: [UUID]) {
        orderedIDs = ids
        if let selectedID, ids.contains(selectedID) {
            return
        }
        selectedID = ids.first
        previewedID = nil
    }

    func select(_ id: UUID) {
        guard orderedIDs.contains(id) else { return }
        selectedID = id
    }

    func moveUp() {
        move(delta: -1)
    }

    func moveDown() {
        move(delta: 1)
    }

    func togglePreview() {
        guard let selectedID else { return }
        previewedID = (previewedID == selectedID) ? nil : selectedID
    }

    func closePreview() {
        previewedID = nil
    }

    private func move(delta: Int) {
        guard let selectedID,
              let index = orderedIDs.firstIndex(of: selectedID),
              !orderedIDs.isEmpty else { return }
        let next = min(max(index + delta, 0), orderedIDs.count - 1)
        self.selectedID = orderedIDs[next]
    }
}
```

- [ ] **Step 4: Run selection tests**

Run:

```bash
swift test --filter ClipboardHistorySelectionModelTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/ClipboardHistorySelectionModel.swift Tests/AnyDoorTests/ClipboardHistorySelectionModelTests.swift
git commit -m "feat(history): add history popover selection model"
```

### Task 8: Add ClipboardHistoryPopoverView

**Files:**
- Create: `Sources/AnyDoor/Views/ClipboardHistoryPopoverView.swift`
- Modify: `Tests/AnyDoorTests/ClipboardHistorySelectionModelTests.swift` if needed for additional copy intent behavior

- [ ] **Step 1: Implement popover view using store cache**

Create a compact SwiftUI view:

- Header: `kind.title` and count.
- Empty state: `暂无历史`.
- Scroll list: newest-first `store.items(for: kind)`.
- Row tap: `Task { try await store.copyToPasteboard(item); onCopyAndClosePanel() }`, catch shows `ToastPresenter.shared.show(.failure("复制失败"))`.
- Row hover: `selection.select(item.id)`.
- `onAppear`: `selection.replaceItems(items.map(\.id))`.
- Keyboard monitor handles:
  - Up: `selection.moveUp()`
  - Down: `selection.moveDown()`
  - Space: `selection.togglePreview()`
  - Return: copy selected item and close panel
  - Esc: close preview if open, otherwise `onDismissPopover()`

Do not fetch SwiftData from the view body. Use `store.items(for:)`.

- [ ] **Step 2: Add preview rendering**

Implement preview overlay or inline sheet within the popover:

- OCR / QR: `ScrollView { Text(text) }`
- Color: `RoundedRectangle` swatch using `Color(hex:)` support from `NSColor+Hex.swift` if available, or parse defensively.
- Screenshot: `NSImage(contentsOf:)` from the store's file URL helper. If no helper is public, add a read-only `imageURL(for:)` API to `ClipboardHistoryStore`.

Keep the view around 300-360 px wide, matching the existing side-popover scale used by `PortManagerPopoverView`. Text must line-wrap and not overflow.

- [ ] **Step 3: Add keyboard monitor**

Follow the pattern in `PortManagerPopoverView.KeyboardMonitor`: extract primitive values from `NSEvent`, then use `MainActor.assumeIsolated` to call the model/view closures. Do not carry `NSEvent` across actor boundaries.

- [ ] **Step 4: Run build and selection tests**

Run:

```bash
swift test --filter ClipboardHistorySelectionModelTests
make build
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/ClipboardHistoryPopoverView.swift Sources/AnyDoor/Views/ClipboardHistorySelectionModel.swift Tests/AnyDoorTests/ClipboardHistorySelectionModelTests.swift
git commit -m "feat(history): add generated clipboard history popover"
```

### Task 9: Generalize MenuBarView Hover Targets

**Files:**
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift`

- [ ] **Step 1: Introduce hover target enum**

Inside `MenuBarView.swift`, add private enum near `MenuBarView`:

```swift
private enum HoverPopoverTarget: Hashable {
    case submenu(BuiltinItem)
    case history(ClipboardHistoryKind)
}
```

Replace:

```swift
@State private var triggerFrames: [BuiltinItem: NSRect] = [:]
@State private var activeSubmenu: BuiltinItem? = nil
```

with:

```swift
@State private var triggerFrames: [HoverPopoverTarget: NSRect] = [:]
@State private var activeHoverTarget: HoverPopoverTarget? = nil
```

- [ ] **Step 2: Update row rendering**

For built-in submenu rows, use `.submenu(item)` target. For built-in action rows with `item.historyKind`, use `.history(historyKind)` target while preserving `onAction`.

The action row still calls:

```swift
Task { await panel.run(builtin) }
```

on click.

- [ ] **Step 3: Add target-aware hover handling**

Add helpers:

```swift
private func triggerHover(_ hovered: Bool, target: HoverPopoverTarget) {
    if hovered {
        let changed = activeHoverTarget != target
        activeHoverTarget = target
        if changed, gate.isShown {
            mountPopoverContent(for: target)
            popover?.show(anchoredTo: convertedTriggerFrame(for: target))
            return
        }
        gate.triggerHover(true)
        return
    }

    guard activeHoverTarget == target else { return }
    gate.triggerHover(false)
}
```

If the popover is already visible and target changes, remount and re-anchor immediately. If `HoverGate` does not expose visibility enough to implement that cleanly, add a small method to `HoverGate` such as `remountShown()` or call `gate.showImmediately()` after setting the target. Keep the API small.

- [ ] **Step 4: Update `wireGate` and mount content**

Change:

```swift
private func mountPopoverContent(for item: BuiltinItem)
```

to:

```swift
private func mountPopoverContent(for target: HoverPopoverTarget)
```

Cases:

- `.submenu(.appShortcuts)`: existing App Shortcuts content, `needsKeyFocus = false`.
- `.submenu(.portManager)`: existing Port Manager content, `needsKeyFocus = true`.
- `.history(let kind)`: set `needsKeyFocus = true`, prune throttled, reload kind, mount `ClipboardHistoryPopoverView`.

History close callbacks:

```swift
onDismissPopover: {
    gate.reset()
    popover.hide()
},
onCopyAndClosePanel: {
    gate.reset()
    popover.hide()
    onRequestClose()
}
```

- [ ] **Step 5: Run build**

Run:

```bash
make build
```

Expected: build passes.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Views/MenuBarView.swift
git commit -m "feat(history): show generated history from action row hover"
```

---

## Chunk 4: Settings, Verification, And QA

### Task 10: Add Clear History Control

**Files:**
- Modify: `Sources/AnyDoor/Views/GeneralSettingsView.swift`
- Modify: `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`

- [ ] **Step 1: Ensure clearAll store test exists**

If Task 3 already added `testClearAllDeletesRowsAndScreenshotFiles`, keep it. If not, add it now and run:

```bash
swift test --filter ClipboardHistoryStoreTests/testClearAllDeletesRowsAndScreenshotFiles
```

Expected before implementation: fail if `clearAll` is missing or incomplete.

- [ ] **Step 2: Add Settings UI**

In `GeneralSettingsView`, add a section near permissions or about/update:

```swift
Section("历史记录") {
    Button(role: .destructive) {
        Task { await ClipboardHistoryStore.shared.clearAll() }
    } label: {
        Label("清空剪贴历史", systemImage: "trash")
    }
}
```

If a confirmation alert is desired, use a simple `@State private var confirmingClearHistory = false`. Do not overbuild; this button is in Settings, already away from accidental panel clicks.

- [ ] **Step 3: Run tests and build**

Run:

```bash
swift test --filter ClipboardHistoryStoreTests
make build
```

Expected: pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/GeneralSettingsView.swift Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift
git commit -m "feat(history): add clear history setting"
```

### Task 11: Final Targeted Tests

**Files:**
- No code changes unless failures reveal bugs.

- [ ] **Step 1: Run focused history tests**

Run:

```bash
swift test --filter ClipboardHistory
```

Expected: all generated clipboard history tests pass.

- [ ] **Step 2: Run built-in metadata tests**

Run:

```bash
swift test --filter BuiltinItemTests
```

Expected: pass.

- [ ] **Step 3: Run panel store tests**

Run:

```bash
swift test --filter PanelStoreTests
```

Expected: pass.

- [ ] **Step 4: Run build**

Run:

```bash
make build
```

Expected: build complete with no Swift errors.

- [ ] **Step 5: Commit fixes if needed**

Only commit if final verification required code changes:

```bash
git add Sources/AnyDoor Tests/AnyDoorTests Package.swift Makefile docs/superpowers/plans/2026-05-24-clipboard-history.md
git commit -m "fix(history): stabilize generated clipboard history"
```

### Task 12: Manual QA Checklist

**Files:**
- No source changes unless QA finds bugs.

- [ ] **Step 1: Launch dev app**

Run:

```bash
swift run AnyDoor
```

Expected: app launches and menu bar icon appears. If Accessibility permission is missing, grant it for the `swift run` process identity.

- [ ] **Step 2: OCR history**

1. Click `屏幕取词`.
2. Select a text region.
3. Confirm existing toast says copied.
4. Hover `屏幕取词`.
5. Confirm OCR history popover appears.
6. Click a history row.
7. Confirm it copies text and closes both popover and main panel.

- [ ] **Step 3: Color history**

1. Click `屏幕取色`.
2. Pick a color.
3. Hover `屏幕取色`.
4. Confirm row shows HEX and preview `Space` shows swatch.
5. Press `Enter`.
6. Confirm HEX is copied and panels close.

- [ ] **Step 4: QR history**

1. Click `识别二维码`.
2. Select a QR code.
3. Hover `识别二维码`.
4. Confirm payload appears only in history, not toast.
5. Press `Space` to preview.
6. Press `Esc` to close preview.

- [ ] **Step 5: Screenshot history**

1. Click `截图到剪贴板`.
2. Capture a region.
3. Hover `截图到剪贴板`.
4. Confirm screenshot thumbnail appears.
5. Press `Space` to preview full screenshot.
6. Click the history row.
7. Confirm image is copied and panels close.

On macOS 15+ the first screenshot history record may trigger a pasteboard-access prompt. That is expected.

- [ ] **Step 6: Hover target switching**

Move directly from OCR row to color row to QR row to screenshot row.

Expected: popover content remounts for the newly hovered row, re-anchors correctly, and stale hide events do not close the new popover.

- [ ] **Step 7: Settings clear history**

1. Open Settings.
2. Click `清空剪贴历史`.
3. Hover each history-capable row.

Expected: each popover shows empty state.

- [ ] **Step 8: Stop app**

Stop the running `swift run AnyDoor` process before handing off.

### Task 13: Final Commit And Handoff

**Files:**
- `CHANGELOG.md` only if the user wants release notes in this implementation pass.

- [ ] **Step 1: Check git status**

Run:

```bash
git status --short
```

Expected: clean or only intentional changes.

- [ ] **Step 2: Summarize verification**

Record the exact commands run:

- `swift test --filter ClipboardHistory`
- `swift test --filter BuiltinItemTests`
- `swift test --filter PanelStoreTests`
- `make build`
- manual QA status

- [ ] **Step 3: Handoff**

Final response must mention:

- Files changed by area.
- Tests/commands run and pass/fail status.
- Manual QA status.
- Any known limitation, especially macOS pasteboard prompt for screenshot history.

---

## Implementation Notes

- Do not add a clipboard watcher. If implementation starts polling `NSPasteboard.general`, it has left the approved scope.
- Do not convert the four action rows into submenus. They must keep action hotkeys.
- Do not show QR payloads in toasts.
- Do not make retention configurable in this pass.
- Do not add dependencies for PNG handling; AppKit/ImageIO is enough.
- Keep comments in English. UI strings stay Chinese.
