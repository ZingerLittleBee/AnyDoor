# Clipboard History (Paste-style) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Paste-style clipboard manager: a background watcher captures copied text/images/files, and a hotkey-summoned bottom card wall lets the user browse, search, favorite, and re-paste entries (Enter restores rich text, Option+Enter pastes plain).

**Architecture:** Extends the existing `@MainActor @Observable ClipboardHistoryStore` (kind-keyed SwiftData records + prune + clearAll). New units: `ClipboardCapture` (pure pasteboard classification), `ClipboardWatcher` (timer poll + privacy filter), `ClipboardPasteService` (write-back + synthesized ⌘V), `ClipboardWallState`/`ClipboardWallView`/`ClipboardWallWindowController` (the overlay UI), and `ClipboardWallProvider` (panel/hotkey integration via the existing `runBuiltin` path). The four existing per-kind hover popovers stay; their content merges into the wall's unified timeline as fixed category tabs.

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftUI + AppKit (`NSPanel`), SwiftData, CGEvent synthesis, XCTest. SPM build.

**Spec:** `docs/superpowers/specs/2026-06-01-clipboard-history-design.md`

**Conventions (from CLAUDE.md):**
- All code comments in English; UI-facing strings in Chinese via `L(.key)`.
- New `L10n.Key` cases require BOTH an enum case in `Sources/AnyDoor/Utilities/L10n.swift` AND a matching entry in `Sources/AnyDoor/Resources/Localizable.xcstrings` (`L10n.Key` is `CaseIterable`; `BuiltinItemLocalizationTests`/catalog coverage tests fail if a key has no catalog entry). Add both, with `zh` (primary) and `en` strings.
- Commits: Conventional Commits, imperative, lowercase subject, no `Co-Authored-By`, no generation signatures, no `@`.
- Build: `swift build`. Test: `swift test`. Run a single test: `swift test --filter AnyDoorTests.ClipboardCaptureTests`.

**`modifierFlags` integer convention:** stored as the raw bitmask shared by `NSEvent.ModifierFlags` and `CGEventFlags` (same bit layout). `⌘⇧` = `0x12_0000` (command `0x10_0000` | shift `0x2_0000`). `V` keyCode = `9` (`kVK_ANSI_V`).

---

## File Structure

**Create:**
- `Sources/AnyDoor/Services/ClipboardCapture.swift` — pure classification of a pasteboard snapshot into a `CapturedClipboard` value.
- `Sources/AnyDoor/Services/ClipboardWatcher.swift` — `@MainActor` timer poll, privacy filter, self-write suppression.
- `Sources/AnyDoor/Services/ClipboardPasteService.swift` — write a history item back to the pasteboard; synthesize ⌘V.
- `Sources/AnyDoor/Services/ClipboardPreferences.swift` — `UserDefaults`-backed settings (keys + typed accessors).
- `Sources/AnyDoor/Services/Providers/ClipboardWallProvider.swift` — `@MainActor` `ActionProvider` that toggles the wall.
- `Sources/AnyDoor/Views/ClipboardWallState.swift` — `@Observable` filter/search/selection model.
- `Sources/AnyDoor/Views/ClipboardWallView.swift` — SwiftUI card wall (tabs + search + horizontal cards).
- `Sources/AnyDoor/Views/ClipboardCardView.swift` — single card.
- `Sources/AnyDoor/Views/ClipboardWallWindowController.swift` — bottom full-width `NSPanel`, key monitor, keyboard nav.
- `Tests/AnyDoorTests/ClipboardCaptureTests.swift`
- `Tests/AnyDoorTests/ClipboardWatcherTests.swift`
- `Tests/AnyDoorTests/ClipboardWallStateTests.swift`

**Modify:**
- `Sources/AnyDoor/Models/ClipboardHistoryItem.swift` — new kinds + fields.
- `Sources/AnyDoor/Services/ClipboardHistoryStore.swift` — record/query/favorite/delete/prune extensions.
- `Sources/AnyDoor/Models/BuiltinItem.swift` — `.clipboardWall` case.
- `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift` — default `⌘⇧V` hotkey seed.
- `Sources/AnyDoor/AppDelegate.swift` — register provider + start watcher.
- `Sources/AnyDoor/Views/GeneralSettingsView.swift` — clipboard settings section.
- `Sources/AnyDoor/Utilities/L10n.swift` + `Sources/AnyDoor/Resources/Localizable.xcstrings` — new keys.
- `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift` — new record/query/prune tests.

---

## Task 1: Extend the data model

**Files:**
- Modify: `Sources/AnyDoor/Models/ClipboardHistoryItem.swift`
- Test: `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`

- [ ] **Step 1: Write the failing test** (append to `ClipboardHistoryStoreTests`)

```swift
func testNewKindsAndFieldsPersist() throws {
    let item = ClipboardHistoryItem(
        kind: .text,
        text: "hello",
        previewTitle: "hello",
        richData: Data([0x01, 0x02]),
        richType: "public.rtf",
        sourceBundleID: "com.apple.Safari",
        sourceAppName: "Safari",
        isFavorite: true
    )
    XCTAssertEqual(item.historyKind, .text)
    XCTAssertEqual(item.richType, "public.rtf")
    XCTAssertEqual(item.sourceAppName, "Safari")
    XCTAssertTrue(item.isFavorite)
    XCTAssertEqual(ClipboardHistoryKind.file.titleKey, .clipboardKindFile)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnyDoorTests.ClipboardHistoryStoreTests/testNewKindsAndFieldsPersist`
Expected: FAIL — compile error (no `.text` case, no `richData` init param, no `.clipboardKindFile`).

- [ ] **Step 3: Implement the model changes**

In `ClipboardHistoryKind`, add the three new cases and their title keys:

```swift
enum ClipboardHistoryKind: String, CaseIterable, Sendable {
    case ocr
    case color
    case qrcode
    case screenshot
    case text
    case image
    case file

    var titleKey: L10n.Key {
        switch self {
        case .ocr:        return .clipboardKindOcr
        case .color:      return .clipboardKindColor
        case .qrcode:     return .clipboardKindQrcode
        case .screenshot: return .clipboardKindScreenshot
        case .text:       return .clipboardKindText
        case .image:      return .clipboardKindImage
        case .file:       return .clipboardKindFile
        }
    }
}
```

Add a `Codable` manifest entry type (one struct per copied file) at file scope:

```swift
/// One file inside a `.file` clipboard entry. `storedName` is the copy held in
/// the history directory; `originalName` is shown on the card. For
/// reference-only entries (over the size ceiling) `storedName` is nil and the
/// original on-disk path is kept in `originalPath` for write-back.
struct ClipboardFileEntry: Codable, Sendable, Hashable {
    var storedName: String?
    var originalName: String
    var originalPath: String
}
```

Extend `ClipboardHistoryItem` with the new optional properties and init params
(all defaulted so existing call sites and the SwiftData migration stay lightweight):

```swift
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

    // Paste-style additions.
    var richData: Data?
    var richType: String?
    var sourceBundleID: String?
    var sourceAppName: String?
    var isFavorite: Bool = false
    var filesManifest: Data?
    var isReferenceOnly: Bool = false

    init(
        id: UUID = UUID(),
        kind: ClipboardHistoryKind,
        text: String? = nil,
        fileName: String? = nil,
        colorHex: String? = nil,
        previewTitle: String,
        previewSubtitle: String? = nil,
        createdAt: Date = Date(),
        richData: Data? = nil,
        richType: String? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        isFavorite: Bool = false,
        filesManifest: Data? = nil,
        isReferenceOnly: Bool = false
    ) {
        self.id = id
        self.kind = kind.rawValue
        self.text = text
        self.fileName = fileName
        self.colorHex = colorHex
        self.previewTitle = previewTitle
        self.previewSubtitle = previewSubtitle
        self.createdAt = createdAt
        self.richData = richData
        self.richType = richType
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.isFavorite = isFavorite
        self.filesManifest = filesManifest
        self.isReferenceOnly = isReferenceOnly
    }

    @Transient var historyKind: ClipboardHistoryKind? {
        ClipboardHistoryKind(rawValue: kind)
    }

    /// Decoded file manifest for `.file` entries, or `[]`.
    @Transient var files: [ClipboardFileEntry] {
        guard let filesManifest else { return [] }
        return (try? JSONDecoder().decode([ClipboardFileEntry].self, from: filesManifest)) ?? []
    }
}
```

- [ ] **Step 4: Add the new L10n keys** (so the test compiles)

In `Sources/AnyDoor/Utilities/L10n.swift`, add cases (keep alphabetical grouping near other `clipboardKind*`):

```swift
case clipboardKindText = "clipboard.kind.text"
case clipboardKindImage = "clipboard.kind.image"
case clipboardKindFile = "clipboard.kind.file"
```

In `Sources/AnyDoor/Resources/Localizable.xcstrings`, add matching entries. Pattern (mirror an existing `clipboard.kind.*` entry exactly):

```json
"clipboard.kind.text" : { "localizations" : {
  "en" : { "stringUnit" : { "state" : "translated", "value" : "Text" } },
  "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "文本" } } } },
"clipboard.kind.image" : { "localizations" : {
  "en" : { "stringUnit" : { "state" : "translated", "value" : "Image" } },
  "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "图片" } } } },
"clipboard.kind.file" : { "localizations" : {
  "en" : { "stringUnit" : { "state" : "translated", "value" : "File" } },
  "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "文件" } } } }
```

> Check an existing `clipboard.kind.color` block in the catalog and copy its exact JSON shape (key names, `extractionState`, etc.) — the schema above is the minimum; match what's already there.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter AnyDoorTests.ClipboardHistoryStoreTests/testNewKindsAndFieldsPersist`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Models/ClipboardHistoryItem.swift Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift
git commit -m "feat(clipboard): extend history model with text/image/file kinds and paste metadata"
```

---

## Task 2: Pure pasteboard classification (`ClipboardCapture`)

Pure, side-effect-free classification so it can be unit-tested without a timer.

**Files:**
- Create: `Sources/AnyDoor/Services/ClipboardCapture.swift`
- Test: `Tests/AnyDoorTests/ClipboardCaptureTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import AppKit
import XCTest
@testable import AnyDoor

final class ClipboardCaptureTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorTest-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func testPlainTextClassifiesAsText() throws {
        let pb = pasteboard()
        pb.setString("  hello world  ", forType: .string)
        let captured = try XCTUnwrap(ClipboardCapture.classify(pb))
        guard case .text(let plain, let rich, let richType) = captured else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(plain, "hello world")   // trimmed
        XCTAssertNil(rich)
        XCTAssertNil(richType)
    }

    func testRichTextKeepsRtfPayload() throws {
        let pb = pasteboard()
        let attributed = NSAttributedString(string: "styled")
        let rtf = try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length)))
        pb.setData(rtf, forType: .rtf)
        pb.setString("styled", forType: .string)
        let captured = try XCTUnwrap(ClipboardCapture.classify(pb))
        guard case .text(let plain, let rich, let richType) = captured else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(plain, "styled")
        XCTAssertEqual(rich, rtf)
        XCTAssertEqual(richType, NSPasteboard.PasteboardType.rtf.rawValue)
    }

    func testConcealedTypeIsSkipped() {
        let pb = pasteboard()
        pb.setString("s3cret", forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        XCTAssertNil(ClipboardCapture.classify(pb))
    }

    func testTransientTypeIsSkipped() {
        let pb = pasteboard()
        pb.setString("tmp", forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        XCTAssertNil(ClipboardCapture.classify(pb))
    }

    func testEmptyOrWhitespaceTextIsSkipped() {
        let pb = pasteboard()
        pb.setString("   \n  ", forType: .string)
        XCTAssertNil(ClipboardCapture.classify(pb))
    }

    func testImageClassifiesAsImage() throws {
        let pb = pasteboard()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        XCTAssertTrue(pb.writeObjects([image]))
        let captured = try XCTUnwrap(ClipboardCapture.classify(pb))
        guard case .image(let png) = captured else { return XCTFail("expected image") }
        XCTAssertFalse(png.isEmpty)
    }

    func testFileUrlsClassifyAsFiles() throws {
        let pb = pasteboard()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(pb.writeObjects([url as NSURL]))
        let captured = try XCTUnwrap(ClipboardCapture.classify(pb))
        guard case .files(let urls) = captured else { return XCTFail("expected files") }
        XCTAssertEqual(urls.first?.lastPathComponent, url.lastPathComponent)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnyDoorTests.ClipboardCaptureTests`
Expected: FAIL — `ClipboardCapture` undefined.

- [ ] **Step 3: Implement `ClipboardCapture`**

```swift
import AppKit
import Foundation

/// The classified result of reading a pasteboard snapshot. A pure value type
/// so capture logic is testable without timers or the live general pasteboard.
enum CapturedClipboard: Sendable, Equatable {
    case text(plain: String, rich: Data?, richType: String?)
    case image(png: Data)
    case files(urls: [URL])
}

/// Side-effect-free pasteboard classification + privacy filtering.
enum ClipboardCapture {
    /// Pasteboard markers set by password managers / apps that opt out of history.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Rich text representations we try to preserve, richest first.
    private static let richTextTypes: [NSPasteboard.PasteboardType] = [.rtf, .html]

    /// Classify a pasteboard's current contents. Returns nil when the content
    /// should not be recorded (concealed/transient/empty/unsupported).
    static func classify(_ pasteboard: NSPasteboard) -> CapturedClipboard? {
        let types = pasteboard.types ?? []
        if types.contains(concealedType) || types.contains(transientType) { return nil }

        // Files take priority over their textual URL representation.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls: urls)
        }

        // Images (excluding the file case handled above).
        if let image = NSImage(pasteboard: pasteboard), let png = pngData(from: image) {
            return .image(png: png)
        }

        // Text, preserving the richest available styled representation.
        if let plain = pasteboard.string(forType: .string) {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            for type in richTextTypes {
                if let data = pasteboard.data(forType: type) {
                    return .text(plain: trimmed, rich: data, richType: type.rawValue)
                }
            }
            return .text(plain: trimmed, rich: nil, richType: nil)
        }

        return nil
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AnyDoorTests.ClipboardCaptureTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardCapture.swift Tests/AnyDoorTests/ClipboardCaptureTests.swift
git commit -m "feat(clipboard): add pure pasteboard capture classifier with privacy filtering"
```

---

## Task 3: Store record methods for text / image / file

**Files:**
- Modify: `Sources/AnyDoor/Services/ClipboardHistoryStore.swift`
- Test: `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testRecordCapturedTextStoresPlainAndRich() async throws {
    let container = try makeContainer()
    let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
    store.bootstrap(modelContainer: container)

    await store.record(
        .text(plain: "hello\nworld", rich: Data([0x09]), richType: "public.rtf"),
        source: ClipboardSource(bundleID: "com.apple.Safari", appName: "Safari")
    )
    await store.reload(kind: .text)

    let item = try XCTUnwrap(store.items(for: .text).first)
    XCTAssertEqual(item.text, "hello\nworld")
    XCTAssertEqual(item.previewTitle, "hello")
    XCTAssertEqual(item.richType, "public.rtf")
    XCTAssertEqual(item.sourceAppName, "Safari")
}

func testRecordCapturedImageStoresPng() async throws {
    let container = try makeContainer()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) }, historyDirectory: directory)
    store.bootstrap(modelContainer: container)

    await store.record(.image(png: Data([0x89, 0x50, 0x4E, 0x47])), source: nil)
    await store.reload(kind: .image)

    let item = try XCTUnwrap(store.items(for: .image).first)
    let fileName = try XCTUnwrap(item.fileName)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path))
    try? FileManager.default.removeItem(at: directory)
}

func testRecordCapturedFileCopiesIntoStorage() async throws {
    let container = try makeContainer()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) }, historyDirectory: directory)
    store.bootstrap(modelContainer: container)

    let src = FileManager.default.temporaryDirectory.appendingPathComponent("doc-\(UUID().uuidString).txt")
    try Data("payload".utf8).write(to: src)
    defer { try? FileManager.default.removeItem(at: src) }

    await store.record(.files(urls: [src]), source: nil)
    await store.reload(kind: .file)

    let item = try XCTUnwrap(store.items(for: .file).first)
    let entry = try XCTUnwrap(item.files.first)
    XCTAssertEqual(entry.originalName, src.lastPathComponent)
    XCTAssertFalse(item.isReferenceOnly)
    let stored = try XCTUnwrap(entry.storedName)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(stored).path))
    try? FileManager.default.removeItem(at: directory)
}

func testRecordCapturedFileOverSizeLimitIsReferenceOnly() async throws {
    let container = try makeContainer()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ClipboardHistoryStore(
        now: { Date(timeIntervalSinceReferenceDate: 100) },
        historyDirectory: directory,
        maxCopiedFileBytes: 4
    )
    store.bootstrap(modelContainer: container)

    let src = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).txt")
    try Data(repeating: 0x41, count: 64).write(to: src)
    defer { try? FileManager.default.removeItem(at: src) }

    await store.record(.files(urls: [src]), source: nil)
    await store.reload(kind: .file)

    let item = try XCTUnwrap(store.items(for: .file).first)
    XCTAssertTrue(item.isReferenceOnly)
    XCTAssertNil(item.files.first?.storedName)
    XCTAssertEqual(item.files.first?.originalPath, src.path)
    try? FileManager.default.removeItem(at: directory)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnyDoorTests.ClipboardHistoryStoreTests/testRecordCapturedTextStoresPlainAndRich`
Expected: FAIL — `record(_:source:)`, `ClipboardSource`, `maxCopiedFileBytes` undefined.

- [ ] **Step 3: Implement**

Add a `maxCopiedFileBytes` stored property + init param to `ClipboardHistoryStore`
(designated init around line 40; add to BOTH the designated and convenience inits).
In the designated init add parameter `maxCopiedFileBytes: Int = 25 * 1_024 * 1_024`
and store it; forward it from the convenience init.

Add a Sendable source struct at file scope:

```swift
struct ClipboardSource: Sendable, Equatable {
    let bundleID: String?
    let appName: String?
}
```

Add the unified record entry point + per-kind helpers:

```swift
/// Record a freshly captured clipboard payload. Routing per kind:
/// text → plain + rich; image → PNG on disk; file → copy into storage
/// (or reference-only over the size ceiling).
func record(_ captured: CapturedClipboard, source: ClipboardSource?) async {
    switch captured {
    case .text(let plain, let rich, let richType):
        await recordCapturedText(plain: plain, rich: rich, richType: richType, source: source)
    case .image(let png):
        await recordCapturedImage(png: png, source: source)
    case .files(let urls):
        await recordCapturedFiles(urls: urls, source: source)
    }
}

private func recordCapturedText(plain: String, rich: Data?, richType: String?, source: ClipboardSource?) async {
    guard let container = modelContainer else { return }
    let item = ClipboardHistoryItem(
        kind: .text,
        text: plain,
        previewTitle: Self.previewTitle(for: plain),
        previewSubtitle: Self.textSubtitle(for: plain),
        createdAt: now(),
        richData: rich,
        richType: richType,
        sourceBundleID: source?.bundleID,
        sourceAppName: source?.appName
    )
    container.mainContext.insert(item)
    await saveAndRefresh(kind: .text, container: container)
}

private func recordCapturedImage(png: Data, source: ClipboardSource?) async {
    guard let container = modelContainer else { return }
    do {
        let id = UUID()
        let directory = historyDirectoryProvider()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(id.uuidString).png"
        try png.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        let item = ClipboardHistoryItem(
            id: id,
            kind: .image,
            fileName: fileName,
            previewTitle: "",
            createdAt: now(),
            sourceBundleID: source?.bundleID,
            sourceAppName: source?.appName
        )
        container.mainContext.insert(item)
        await saveAndRefresh(kind: .image, container: container)
    } catch {
        historyLogger.error("Failed to record image history: \(error)")
    }
}

private func recordCapturedFiles(urls: [URL], source: ClipboardSource?) async {
    guard let container = modelContainer, !urls.isEmpty else { return }
    do {
        let directory = historyDirectoryProvider()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fm = FileManager.default
        var entries: [ClipboardFileEntry] = []
        var referenceOnly = false
        for url in urls {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory || size > maxCopiedFileBytes {
                referenceOnly = true
                entries.append(ClipboardFileEntry(storedName: nil, originalName: url.lastPathComponent, originalPath: url.path))
            } else {
                let storedName = "\(UUID().uuidString)-\(url.lastPathComponent)"
                try fm.copyItem(at: url, to: directory.appendingPathComponent(storedName))
                entries.append(ClipboardFileEntry(storedName: storedName, originalName: url.lastPathComponent, originalPath: url.path))
            }
        }
        let manifest = try JSONEncoder().encode(entries)
        let title = entries.count == 1 ? entries[0].originalName : L(.clipboardFileCount, entries.count)
        let item = ClipboardHistoryItem(
            kind: .file,
            previewTitle: title,
            createdAt: now(),
            sourceBundleID: source?.bundleID,
            sourceAppName: source?.appName,
            filesManifest: manifest,
            isReferenceOnly: referenceOnly
        )
        container.mainContext.insert(item)
        await saveAndRefresh(kind: .file, container: container)
    } catch {
        historyLogger.error("Failed to record file history: \(error)")
    }
}

/// Shared save + prune + reload tail used by the record helpers.
private func saveAndRefresh(kind: ClipboardHistoryKind, container: ModelContainer) async {
    do {
        try container.mainContext.save()
        await pruneExpiredAndOverflow(force: true)
        await reload(kind: kind)
    } catch {
        historyLogger.error("Failed to save \(kind.rawValue) history: \(error)")
    }
}
```

Add the L10n key `clipboardFileCount = "clipboard.file.count"` to `L10n.swift`
and `Localizable.xcstrings` (en `"%d files"`, zh-Hans `"%d 个文件"`).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnyDoorTests.ClipboardHistoryStoreTests`
Expected: PASS (all record tests + the existing ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardHistoryStore.swift Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift
git commit -m "feat(clipboard): record captured text, image, and file entries into history"
```

---

## Task 4: Aggregated query + favorite + delete

**Files:**
- Modify: `Sources/AnyDoor/Services/ClipboardHistoryStore.swift`
- Test: `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testTimelineFiltersByCategoryAndSearch() async throws {
    let container = try makeContainer()
    var now = Date(timeIntervalSinceReferenceDate: 100)
    let store = ClipboardHistoryStore(now: { now })
    store.bootstrap(modelContainer: container)

    await store.record(.text(plain: "apple pie", rich: nil, richType: nil), source: nil)
    now = Date(timeIntervalSinceReferenceDate: 200)
    await store.record(.text(plain: "banana bread", rich: nil, richType: nil), source: nil)
    now = Date(timeIntervalSinceReferenceDate: 300)
    await store.recordColor(hex: "#ABCDEF")

    // All → newest first across kinds.
    let all = store.timeline(category: nil, query: "")
    XCTAssertEqual(all.map(\.previewTitle), ["#ABCDEF", "banana bread", "apple"])

    // Category filter.
    let onlyText = store.timeline(category: .text, query: "")
    XCTAssertEqual(onlyText.map(\.previewTitle), ["banana bread", "apple"])

    // Case-insensitive search over preview/text.
    let search = store.timeline(category: nil, query: "APPLE")
    XCTAssertEqual(search.map(\.previewTitle), ["apple"])
}

func testToggleFavoriteAndDelete() async throws {
    let container = try makeContainer()
    let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
    store.bootstrap(modelContainer: container)
    await store.record(.text(plain: "keep me", rich: nil, richType: nil), source: nil)

    let item = try XCTUnwrap(store.timeline(category: nil, query: "").first)
    await store.toggleFavorite(item)
    XCTAssertTrue(try XCTUnwrap(store.timeline(category: nil, query: "").first).isFavorite)

    await store.delete(item)
    XCTAssertTrue(store.timeline(category: nil, query: "").isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnyDoorTests.ClipboardHistoryStoreTests/testTimelineFiltersByCategoryAndSearch`
Expected: FAIL — `timeline(category:query:)`, `toggleFavorite`, `delete` undefined.

- [ ] **Step 3: Implement**

```swift
/// Unified, time-sorted view across all kinds for the card wall. `category`
/// nil means "all"; `query` is a case-insensitive substring over preview title,
/// subtitle, and stored text. Reads directly from SwiftData (not the per-kind
/// cache) so it always reflects every kind in one pass.
func timeline(category: ClipboardHistoryKind?, query: String) -> [ClipboardHistoryItem] {
    guard let container = modelContainer else { return [] }
    let cutoff = now().addingTimeInterval(-maxAge)
    var descriptor = FetchDescriptor<ClipboardHistoryItem>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.predicate = #Predicate { $0.createdAt >= cutoff }
    var rows = (try? container.mainContext.fetch(descriptor)) ?? []

    if let category {
        let raw = category.rawValue
        rows = rows.filter { $0.kind == raw }
    }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        let needle = trimmed.lowercased()
        rows = rows.filter { item in
            item.previewTitle.lowercased().contains(needle)
                || (item.previewSubtitle?.lowercased().contains(needle) ?? false)
                || (item.text?.lowercased().contains(needle) ?? false)
        }
    }
    return rows
}

/// Flip a single item's favorite flag. Favorites are exempt from pruning.
func toggleFavorite(_ item: ClipboardHistoryItem) async {
    guard let container = modelContainer else { return }
    item.isFavorite.toggle()
    try? container.mainContext.save()
    if let kind = item.historyKind { await reload(kind: kind) }
}

/// Delete a single item and its on-disk payload (image PNG / copied files).
func delete(_ item: ClipboardHistoryItem) async {
    guard let container = modelContainer else { return }
    deleteScreenshotFileIfNeeded(for: item)   // covers .screenshot and .image (both use fileName)
    deleteCopiedFilesIfNeeded(for: item)
    let kind = item.historyKind
    container.mainContext.delete(item)
    try? container.mainContext.save()
    if let kind { await reload(kind: kind) }
}

/// Remove copied-file payloads for a `.file` entry (no-op for reference-only).
private func deleteCopiedFilesIfNeeded(for item: ClipboardHistoryItem) {
    guard item.kind == ClipboardHistoryKind.file.rawValue else { return }
    let directory = historyDirectoryProvider()
    for entry in item.files {
        if let stored = entry.storedName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(stored))
        }
    }
}
```

Update `deleteScreenshotFileIfNeeded` so it also covers `.image` items (both
persist a single PNG under `fileName`):

```swift
private func deleteScreenshotFileIfNeeded(for item: ClipboardHistoryItem) {
    guard item.kind == ClipboardHistoryKind.screenshot.rawValue
            || item.kind == ClipboardHistoryKind.image.rawValue,
          let fileName = item.fileName else { return }
    let url = historyDirectoryProvider().appendingPathComponent(fileName)
    try? FileManager.default.removeItem(at: url)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnyDoorTests.ClipboardHistoryStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardHistoryStore.swift Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift
git commit -m "feat(clipboard): add unified timeline query, favorite toggle, and single-item delete"
```

---

## Task 5: Configurable retention + favorite exemption in prune

**Files:**
- Modify: `Sources/AnyDoor/Services/ClipboardHistoryStore.swift`
- Test: `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testPruneExemptsFavorites() async throws {
    let container = try makeContainer()
    let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
    let store = ClipboardHistoryStore(now: { now }, maxItemsPerKind: 1)
    store.bootstrap(modelContainer: container)

    let context = container.mainContext
    // Two text rows; the OLDER one is favorited and must survive the overflow trim.
    context.insert(ClipboardHistoryItem(kind: .text, text: "old", previewTitle: "old", createdAt: now.addingTimeInterval(1), isFavorite: true))
    context.insert(ClipboardHistoryItem(kind: .text, text: "new", previewTitle: "new", createdAt: now.addingTimeInterval(2)))
    try context.save()

    await store.pruneExpiredAndOverflow(force: true)
    let titles = Set(store.timeline(category: .text, query: "").map(\.previewTitle))
    XCTAssertTrue(titles.contains("old"))   // favorite survived
    XCTAssertTrue(titles.contains("new"))
}

func testUnlimitedRetentionKeepsOldRows() async throws {
    let container = try makeContainer()
    let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
    let store = ClipboardHistoryStore(now: { now }, maxAge: .infinity)
    store.bootstrap(modelContainer: container)

    let context = container.mainContext
    context.insert(ClipboardHistoryItem(kind: .text, text: "ancient", previewTitle: "ancient", createdAt: now.addingTimeInterval(-3650 * 86_400)))
    try context.save()

    await store.pruneExpiredAndOverflow(force: true)
    XCTAssertEqual(store.timeline(category: .text, query: "").map(\.previewTitle), ["ancient"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnyDoorTests.ClipboardHistoryStoreTests/testPruneExemptsFavorites`
Expected: FAIL — favorited row gets pruned (current prune ignores `isFavorite`).

- [ ] **Step 3: Implement**

In `pruneExpiredAndOverflow`, exempt favorites from both age and overflow eviction.
Replace the deletion-collection block so favorites are never added to `idsToDelete`:

```swift
let cutoff = current.addingTimeInterval(-maxAge)   // maxAge == .infinity → cutoff == .distantPast, nothing expires
var idsToDelete = Set<UUID>()

for item in all where !item.isFavorite && item.createdAt < cutoff {
    idsToDelete.insert(item.id)
}

for kind in ClipboardHistoryKind.allCases {
    let rows = all
        .filter { $0.kind == kind.rawValue && !item_isFavorite($0) && !idsToDelete.contains($0.id) }
        .sorted { $0.createdAt > $1.createdAt }
    for item in rows.dropFirst(maxItemsPerKind) {
        idsToDelete.insert(item.id)
    }
}
```

Add a tiny local helper near the top of the type to keep the filter readable:

```swift
private func item_isFavorite(_ item: ClipboardHistoryItem) -> Bool { item.isFavorite }
```

> Note: `maxAge` is already an init parameter (default `7 * 86_400`). Passing
> `.infinity` makes `cutoff == .distantPast` so the age sweep deletes nothing.
> Settings (Task 8) will pass 7 days / 30 days / `.infinity` at bootstrap.

Also extend the orphan-file sweep at the end of `pruneExpiredAndOverflow` so it
keeps surviving `.image` PNGs and surviving copied `.file` payloads (today it only
keeps `.screenshot` files). Replace `survivingFiles` construction:

```swift
var survivingFiles = Set<String>()
for item in all where !idsToDelete.contains(item.id) {
    if item.kind == ClipboardHistoryKind.screenshot.rawValue || item.kind == ClipboardHistoryKind.image.rawValue {
        if let f = item.fileName { survivingFiles.insert(f) }
    }
    if item.kind == ClipboardHistoryKind.file.rawValue {
        for entry in item.files { if let s = entry.storedName { survivingFiles.insert(s) } }
    }
}
removeOrphanScreenshotFiles(keeping: survivingFiles)
```

And broaden `removeOrphanScreenshotFiles` to not restrict by `.png` extension
(copied files have arbitrary extensions). Change its sweep loop to:

```swift
for url in contents {
    if !survivingFiles.contains(url.lastPathComponent) {
        try? fm.removeItem(at: url)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnyDoorTests.ClipboardHistoryStoreTests`
Expected: PASS (new + existing prune tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardHistoryStore.swift Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift
git commit -m "feat(clipboard): exempt favorites from pruning and sweep image/file payloads"
```

---

## Task 6: Paste service (write-back + synthesized ⌘V)

**Files:**
- Create: `Sources/AnyDoor/Services/ClipboardPasteService.swift`
- Test: `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift` (payload-writing only)

The ⌘V synthesis itself is not unit-tested (it posts a system event); we unit-test
the pasteboard payload writer, which is the part with branching logic.

- [ ] **Step 1: Write the failing test**

```swift
func testPastePayloadPlainVsRich() throws {
    let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorPaste-\(UUID().uuidString)"))

    let rich = NSAttributedString(string: "styled")
    let rtf = try XCTUnwrap(rich.rtf(from: NSRange(location: 0, length: rich.length)))
    let item = ClipboardHistoryItem(kind: .text, text: "styled", previewTitle: "styled",
                                    richData: rtf, richType: NSPasteboard.PasteboardType.rtf.rawValue)

    ClipboardPasteService.writePayload(for: item, asPlainText: false, to: pb, historyDirectory: nil)
    XCTAssertEqual(pb.data(forType: .rtf), rtf)
    XCTAssertEqual(pb.string(forType: .string), "styled")

    ClipboardPasteService.writePayload(for: item, asPlainText: true, to: pb, historyDirectory: nil)
    XCTAssertNil(pb.data(forType: .rtf))   // plain mode drops rich payload
    XCTAssertEqual(pb.string(forType: .string), "styled")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnyDoorTests.ClipboardHistoryStoreTests/testPastePayloadPlainVsRich`
Expected: FAIL — `ClipboardPasteService` undefined.

- [ ] **Step 3: Implement**

```swift
import AppKit
import Foundation

/// Writes a history item back to the pasteboard and (optionally) synthesizes
/// ⌘V into the previously focused app. Synthesized events are tagged with
/// `kAnyDoorSynthesizedEventTag` so the HotkeyService tap passes them through.
@MainActor
enum ClipboardPasteService {
    /// Write `item` to `pasteboard`. `asPlainText` drops rich/file payloads and
    /// writes only the plain string. `historyDirectory` resolves image/file
    /// payloads on disk; pass nil when only text matters (tests).
    static func writePayload(
        for item: ClipboardHistoryItem,
        asPlainText: Bool,
        to pasteboard: NSPasteboard,
        historyDirectory: URL?
    ) {
        pasteboard.clearContents()
        guard let kind = item.historyKind else { return }

        switch kind {
        case .text, .ocr, .qrcode:
            if !asPlainText, let rich = item.richData, let richType = item.richType {
                pasteboard.setData(rich, forType: NSPasteboard.PasteboardType(richType))
            }
            if let text = item.text { pasteboard.setString(text, forType: .string) }
        case .color:
            if let hex = item.colorHex { pasteboard.setString(hex, forType: .string) }
        case .image, .screenshot:
            guard let dir = historyDirectory, let fileName = item.fileName,
                  let image = NSImage(contentsOf: dir.appendingPathComponent(fileName)) else { return }
            pasteboard.writeObjects([image])
        case .file:
            let dir = historyDirectory
            let urls: [NSURL] = item.files.compactMap { entry in
                if let stored = entry.storedName, let dir {
                    return dir.appendingPathComponent(stored) as NSURL
                }
                let original = URL(fileURLWithPath: entry.originalPath)
                return FileManager.default.fileExists(atPath: original.path) ? original as NSURL : nil
            }
            guard !urls.isEmpty else { return }
            pasteboard.writeObjects(urls)
        }
    }

    /// Returns true if the item can be pasted (file entries whose sources are
    /// all gone return false so the caller can show a failure toast).
    static func canPaste(_ item: ClipboardHistoryItem, historyDirectory: URL) -> Bool {
        guard item.historyKind == .file else { return true }
        return item.files.contains { entry in
            if let stored = entry.storedName {
                return FileManager.default.fileExists(atPath: historyDirectory.appendingPathComponent(stored).path)
            }
            return FileManager.default.fileExists(atPath: entry.originalPath)
        }
    }

    /// Post a tagged ⌘V key-down/up pair to the focused app.
    static func synthesizePaste() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        let vKey: CGKeyCode = 9   // kVK_ANSI_V
        for isDown in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: isDown) else { continue }
            ev.flags = .maskCommand
            ev.setIntegerValueField(.eventSourceUserData, value: kAnyDoorSynthesizedEventTag)
            ev.post(tap: .cghidEventTap)
        }
    }
}
```

> `kAnyDoorSynthesizedEventTag` already exists in the codebase (used by
> `QuickPressEmitter`). Confirm its declaration is visible here; if it lives in a
> file not in this target's module path, it is — it's the same module. Do not
> redeclare it.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AnyDoorTests.ClipboardHistoryStoreTests/testPastePayloadPlainVsRich`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardPasteService.swift Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift
git commit -m "feat(clipboard): add paste service for rich/plain write-back and synthesized paste"
```

---

## Task 7: ClipboardWatcher (poll + privacy + self-write suppression)

**Files:**
- Create: `Sources/AnyDoor/Services/ClipboardWatcher.swift`
- Test: `Tests/AnyDoorTests/ClipboardWatcherTests.swift`

The watcher's `poll()` is driven by a timer in production but is a plain method
so tests can drive it directly with a private pasteboard + a spy store.

- [ ] **Step 1: Write the failing test**

```swift
import AppKit
import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardWatcherTests: XCTestCase {
    private func makeStore() throws -> ClipboardHistoryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipboardHistoryItem.self, configurations: config)
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        return store
    }

    func testPollRecordsNewTextOnce() async throws {
        let store = try makeStore()
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorWatch-\(UUID().uuidString)"))
        let watcher = ClipboardWatcher(store: store, pasteboard: pb, sourceProvider: { nil })

        pb.clearContents(); pb.setString("hello", forType: .string)
        await watcher.poll()
        await watcher.poll()   // no change → no second record
        await store.reload(kind: .text)
        XCTAssertEqual(store.items(for: .text).map(\.text), ["hello"])
    }

    func testPollSkipsExcludedApp() async throws {
        let store = try makeStore()
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorWatch-\(UUID().uuidString)"))
        let watcher = ClipboardWatcher(
            store: store,
            pasteboard: pb,
            sourceProvider: { ClipboardSource(bundleID: "com.banking.secure", appName: "Bank") },
            isExcluded: { $0 == "com.banking.secure" }
        )
        pb.clearContents(); pb.setString("secret", forType: .string)
        await watcher.poll()
        await store.reload(kind: .text)
        XCTAssertTrue(store.items(for: .text).isEmpty)
    }

    func testSelfWriteIsSuppressed() async throws {
        let store = try makeStore()
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorWatch-\(UUID().uuidString)"))
        let watcher = ClipboardWatcher(store: store, pasteboard: pb, sourceProvider: { nil })

        // Simulate AnyDoor writing the pasteboard during a paste, then noting it.
        pb.clearContents(); let cc = pb.setString("from-history", forType: .string) ? pb.changeCount : 0
        watcher.noteSelfWrite(changeCount: cc)
        await watcher.poll()
        await store.reload(kind: .text)
        XCTAssertTrue(store.items(for: .text).isEmpty)   // our own write was ignored
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnyDoorTests.ClipboardWatcherTests`
Expected: FAIL — `ClipboardWatcher` undefined.

- [ ] **Step 3: Implement**

```swift
import AppKit
import Foundation

/// Polls a pasteboard for changes and records them into ClipboardHistoryStore.
/// `poll()` is public so tests can drive it deterministically; production uses
/// a repeating timer started by `start()`.
@MainActor
final class ClipboardWatcher {
    private let store: ClipboardHistoryStore
    private let pasteboard: NSPasteboard
    private let sourceProvider: () -> ClipboardSource?
    private let isExcluded: (String) -> Bool
    private let isEnabled: () -> Bool

    private var lastChangeCount: Int
    private var suppressedChangeCount: Int?
    private var timer: Timer?

    init(
        store: ClipboardHistoryStore,
        pasteboard: NSPasteboard = .general,
        sourceProvider: @escaping () -> ClipboardSource? = ClipboardWatcher.frontmostSource,
        isExcluded: @escaping (String) -> Bool = { ClipboardPreferences.excludedBundleIDs.contains($0) },
        isEnabled: @escaping () -> Bool = { ClipboardPreferences.monitoringEnabled }
    ) {
        self.store = store
        self.pasteboard = pasteboard
        self.sourceProvider = sourceProvider
        self.isExcluded = isExcluded
        self.isEnabled = isEnabled
        self.lastChangeCount = pasteboard.changeCount
    }

    /// Begin polling every 0.5s. macOS has no clipboard-change notification, so
    /// polling changeCount is the conventional approach.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.poll() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Record the changeCount produced by AnyDoor's own pasteboard write so the
    /// next poll does not re-record it (avoids the paste-from-history loop).
    func noteSelfWrite(changeCount: Int) {
        suppressedChangeCount = changeCount
    }

    func poll() async {
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        guard isEnabled() else { return }
        if let suppressed = suppressedChangeCount, suppressed == current {
            suppressedChangeCount = nil
            return
        }

        let source = sourceProvider()
        if let bundleID = source?.bundleID, isExcluded(bundleID) { return }
        guard let captured = ClipboardCapture.classify(pasteboard) else { return }
        await store.record(captured, source: source)
    }

    /// The frontmost app at copy time, used for the card's source icon.
    static func frontmostSource() -> ClipboardSource? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return ClipboardSource(bundleID: app.bundleIdentifier, appName: app.localizedName)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnyDoorTests.ClipboardWatcherTests`
Expected: PASS.

> The watcher references `ClipboardPreferences` in its defaults; that type is
> created in Task 8. To keep this task self-contained and green, add a minimal
> stub of `ClipboardPreferences` now (Task 8 fills in the rest):
> ```swift
> // Sources/AnyDoor/Services/ClipboardPreferences.swift (minimal for Task 7)
> import Foundation
> enum ClipboardPreferences {
>     static var monitoringEnabled: Bool { UserDefaults.standard.object(forKey: "clipboard.monitoringEnabled") as? Bool ?? true }
>     static var excludedBundleIDs: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "clipboard.excludedBundleIDs") ?? []) }
> }
> ```

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardWatcher.swift Sources/AnyDoor/Services/ClipboardPreferences.swift Tests/AnyDoorTests/ClipboardWatcherTests.swift
git commit -m "feat(clipboard): add clipboard watcher with privacy filter and self-write suppression"
```

---

## Task 8: Preferences + Settings UI

**Files:**
- Modify: `Sources/AnyDoor/Services/ClipboardPreferences.swift`
- Modify: `Sources/AnyDoor/Views/GeneralSettingsView.swift`
- Modify: `Sources/AnyDoor/Utilities/L10n.swift` + `Sources/AnyDoor/Resources/Localizable.xcstrings`

No new test (UserDefaults wrappers + SwiftUI form); verified via build + manual check.

- [ ] **Step 1: Flesh out `ClipboardPreferences`**

Replace the Task-7 stub with the full set. `RetentionOption` maps to a `maxAge`
the store consumes at bootstrap.

```swift
import Foundation

enum ClipboardRetention: Int, CaseIterable, Sendable {
    case sevenDays = 7
    case thirtyDays = 30
    case unlimited = 0

    var maxAge: TimeInterval {
        switch self {
        case .unlimited: return .infinity
        case .sevenDays: return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        }
    }
    var titleKey: L10n.Key {
        switch self {
        case .sevenDays:  return .settingsClipboardRetention7
        case .thirtyDays: return .settingsClipboardRetention30
        case .unlimited:  return .settingsClipboardRetentionUnlimited
        }
    }
}

/// Typed UserDefaults accessors for clipboard settings. Keys are namespaced
/// `clipboard.*` and read by the watcher, store bootstrap, and paste service.
enum ClipboardPreferences {
    private static let defaults = UserDefaults.standard

    static let monitoringKey = "clipboard.monitoringEnabled"
    static let copyOnlyKey = "clipboard.copyOnly"
    static let retentionKey = "clipboard.retentionDays"
    static let excludedKey = "clipboard.excludedBundleIDs"

    static var monitoringEnabled: Bool { defaults.object(forKey: monitoringKey) as? Bool ?? true }
    static var copyOnly: Bool { defaults.bool(forKey: copyOnlyKey) }
    static var retention: ClipboardRetention {
        ClipboardRetention(rawValue: defaults.object(forKey: retentionKey) as? Int ?? 30) ?? .thirtyDays
    }
    static var excludedBundleIDs: Set<String> { Set(defaults.stringArray(forKey: excludedKey) ?? []) }
}
```

- [ ] **Step 2: Add L10n keys** (enum + xcstrings, zh primary / en)

```
settingsClipboard = "settings.clipboard"                       zh: 剪贴板 / en: Clipboard
settingsClipboardMonitoring = "settings.clipboard.monitoring"  zh: 启用剪贴板监听 / en: Capture clipboard history
settingsClipboardCopyOnly = "settings.clipboard.copyOnly"      zh: 仅复制，不自动粘贴 / en: Copy only (don't auto-paste)
settingsClipboardRetention = "settings.clipboard.retention"    zh: 保留时长 / en: Keep history for
settingsClipboardRetention7 = "settings.clipboard.retention.7"     zh: 7 天 / en: 7 days
settingsClipboardRetention30 = "settings.clipboard.retention.30"   zh: 30 天 / en: 30 days
settingsClipboardRetentionUnlimited = "settings.clipboard.retention.unlimited"  zh: 不限 / en: Unlimited
```

- [ ] **Step 3: Add a Clipboard section to `GeneralSettingsView`**

Add `@AppStorage` bindings near the other ones (top of the struct):

```swift
@AppStorage(ClipboardPreferences.monitoringKey) private var clipboardMonitoring = true
@AppStorage(ClipboardPreferences.copyOnlyKey) private var clipboardCopyOnly = false
@AppStorage(ClipboardPreferences.retentionKey) private var clipboardRetentionDays = 30
```

Insert a new `Section` immediately BEFORE the existing History section (the one
with the Clear button), so clipboard controls and Clear History sit together:

```swift
Section {
    Toggle(isOn: $clipboardMonitoring) { LocalizedText(.settingsClipboardMonitoring) }
    Toggle(isOn: $clipboardCopyOnly) { LocalizedText(.settingsClipboardCopyOnly) }
    Picker(selection: $clipboardRetentionDays) {
        ForEach(ClipboardRetention.allCases, id: \.rawValue) { option in
            LocalizedText(option.titleKey).tag(option.rawValue)
        }
    } label: { LocalizedText(.settingsClipboardRetention) }
    .pickerStyle(.menu)
} header: {
    LocalizedText(.settingsClipboard)
}
```

> App-exclusion list and disk-budget UI are deferred to a follow-up (the spec
> lists them; a basic editor is more UI than this plan needs). The preference
> keys exist (`excludedKey`) and the watcher honors them, so the exclusion list
> can be populated later without a model change. Note this gap in the PR
> description.

- [ ] **Step 4: Wire retention into store bootstrap** — handled in Task 9 (AppDelegate constructs the store/watcher with `ClipboardPreferences.retention.maxAge`). No code here beyond the picker.

- [ ] **Step 5: Build + manual check**

Run: `swift build`
Expected: builds clean.
Manual: `swift run AnyDoor`, open Settings → General, confirm the Clipboard section renders with the three controls above the Clear History button.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardPreferences.swift Sources/AnyDoor/Views/GeneralSettingsView.swift Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(clipboard): add clipboard preferences and general settings controls"
```

---

## Task 9: BuiltinItem + Provider + seeder + AppDelegate wiring

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift`
- Create: `Sources/AnyDoor/Services/Providers/ClipboardWallProvider.swift`
- Modify: `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift`
- Modify: `Sources/AnyDoor/AppDelegate.swift`
- Modify: `Sources/AnyDoor/Utilities/L10n.swift` + `Localizable.xcstrings`

- [ ] **Step 1: Add `.clipboardWall` to `BuiltinItem`**

Add the case (after `.qrcode`):
```swift
case clipboardWall
```
Add to `kind` — in the `.action` group:
```swift
case .lockScreen, .emptyTrash, .screenshot, .ocr, .qrcode, .pickColor, .displaySleep, .systemSleep,
     .restartFinder, .restartDock, .restartMenuBar, .flushDNS, .clipboardWall,
     .windowLeftHalf, .windowRightHalf, .windowMaximize, .windowCenter: return .action
```
`titleKey`: `case .clipboardWall: return .builtinClipboardWall`
`symbol`: `case .clipboardWall: return "doc.on.clipboard"`
`defaultOrder`: `case .clipboardWall: return 250`  (just after appShortcuts/keepAwake cluster)

Add L10n key `builtinClipboardWall = "builtin.clipboardWall"` (zh: 剪贴板 / en: Clipboard) to `L10n.swift` + xcstrings.

> `BuiltinItemLocalizationTests` enumerates `BuiltinItem.allCases` and asserts a
> non-empty localized title — adding the key satisfies it.

- [ ] **Step 2: Create `ClipboardWallProvider`**

```swift
import AppKit

/// Bridges the clipboard wall into the panel's `ActionProvider` surface so it
/// gets a panel row, settings visibility/order, and a bindable hotkey via the
/// existing `runBuiltin` dispatch. `@MainActor` because it drives an NSPanel.
@MainActor
final class ClipboardWallProvider: ActionProvider {
    let itemKey: BuiltinItem = .clipboardWall
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        ClipboardWallWindowController.shared.toggle()
    }
}
```

> `ClipboardWallWindowController` is built in Task 12. To keep this task
> compiling independently, Task 12 must land before this provider's `run()` is
> exercised. If implementing strictly in order, temporarily stub the controller
> (see Task 12 Step 1's type) — but the recommended order is to do Task 10–12
> then return here. **Simplest: implement Task 9 Steps 1, 3, 4 now and add the
> provider registration (Step 5) only after Task 12.** Mark Step 2/5 done when
> the controller exists.

- [ ] **Step 3: Seed default ⌘⇧V hotkey**

In `BuiltinPreferenceSeeder.swift`, add a one-shot default-hotkey seeding step,
mirroring `applyWindowLayoutBackfillIfNeeded`. Add a flag constant and call it
from `seedIfNeeded` after the window backfill:

```swift
private static let clipboardWallHotkeyFlag = "clipboardWallDefaultHotkey_v1"

@MainActor
private static func applyClipboardWallHotkeyIfNeeded(in context: ModelContext) {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: clipboardWallHotkeyFlag) else { return }
    defer { defaults.set(true, forKey: clipboardWallHotkeyFlag) }   // one-shot regardless of outcome

    // ⌘⇧V — keyCode 9 (kVK_ANSI_V), modifierFlags 0x12_0000 (command|shift).
    let keyCode = 9
    let modifierFlags = 0x12_0000
    do {
        let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
        // Conflict check: if any row already binds this exact combo, leave empty.
        let taken = rows.contains { $0.keyCode == keyCode && $0.modifierFlags == modifierFlags }
        guard !taken else { return }
        guard let row = rows.first(where: { $0.itemKey == BuiltinItem.clipboardWall.rawValue }) else { return }
        guard row.keyCode == nil else { return }   // user already set one
        row.keyCode = keyCode
        row.modifierFlags = modifierFlags
        try context.save()
        logger.info("Seeded default ⌘⇧V hotkey for clipboard wall")
    } catch {
        logger.error("clipboardWall hotkey seed failed: \(error)")
    }
}
```

Call it inside `seedIfNeeded`'s `do` block after `applyWindowLayoutBackfillIfNeeded(in: context)`:
```swift
applyClipboardWallHotkeyIfNeeded(in: context)
```

> KeyBinding app-shortcut combos are NOT in `BuiltinPreference`; this conflict
> check only covers built-ins. That's acceptable for a default seed — the user
> can rebind if it clashes with an app shortcut.

- [ ] **Step 4: Construct store retention + watcher in `AppDelegate`**

`ClipboardHistoryStore.shared` is a singleton with default `maxAge` (7 days). To
honor the retention preference, set it at bootstrap. Add a setter to the store:

```swift
// In ClipboardHistoryStore: allow bootstrap to override retention from prefs.
func setMaxAge(_ newValue: TimeInterval) { self.maxAge = newValue }
```
(Change `maxAge` from `let` to `private(set) var`.)

In `applicationDidFinishLaunching`, right after the existing
`ClipboardHistoryStore.shared.bootstrap(...)` line:
```swift
ClipboardHistoryStore.shared.setMaxAge(ClipboardPreferences.retention.maxAge)
```

Add a stored watcher property on `AppDelegate`:
```swift
private var clipboardWatcher: ClipboardWatcher?
```
And start it after the store bootstrap + prune Task:
```swift
let watcher = ClipboardWatcher(store: ClipboardHistoryStore.shared)
watcher.start()
clipboardWatcher = watcher
ClipboardWallWindowController.shared.watcher = watcher   // for self-write suppression (Task 12)
```

> The `ClipboardWallWindowController.shared.watcher` line depends on Task 12; add
> it when the controller exists.

- [ ] **Step 5: Register the provider** (after Task 12 controller exists)

In the `providers` array in `applicationDidFinishLaunching`, add:
```swift
ClipboardWallProvider(),
```

- [ ] **Step 6: Build + commit**

Run: `swift build`
Expected: builds clean (after Task 12 for the controller-dependent lines).

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift Sources/AnyDoor/Services/Providers/ClipboardWallProvider.swift Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift Sources/AnyDoor/AppDelegate.swift Sources/AnyDoor/Services/ClipboardHistoryStore.swift Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(clipboard): register clipboard wall builtin, provider, default hotkey, and watcher"
```

---

## Task 10: Wall state model (filter / search / selection)

**Files:**
- Create: `Sources/AnyDoor/Views/ClipboardWallState.swift`
- Test: `Tests/AnyDoorTests/ClipboardWallStateTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardWallStateTests: XCTestCase {
    private func items(_ titles: [String]) -> [ClipboardHistoryItem] {
        titles.enumerated().map { idx, t in
            ClipboardHistoryItem(kind: .text, text: t, previewTitle: t,
                                 createdAt: Date(timeIntervalSinceReferenceDate: Double(idx)))
        }
    }

    func testSelectionClampsAndMoves() {
        let state = ClipboardWallState()
        state.setItems(items(["a", "b", "c"]))
        XCTAssertEqual(state.selectedIndex, 0)
        state.moveRight(); state.moveRight(); state.moveRight()   // clamps at last
        XCTAssertEqual(state.selectedIndex, 2)
        state.moveLeft()
        XCTAssertEqual(state.selectedIndex, 1)
        XCTAssertEqual(state.selectedItem?.previewTitle, "b")
    }

    func testCategoryAndSearchAreHeld() {
        let state = ClipboardWallState()
        state.category = .image
        state.query = "foo"
        XCTAssertEqual(state.category, .image)
        XCTAssertEqual(state.query, "foo")
    }

    func testEmptyItemsHasNilSelection() {
        let state = ClipboardWallState()
        state.setItems([])
        XCTAssertNil(state.selectedItem)
        XCTAssertEqual(state.selectedIndex, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AnyDoorTests.ClipboardWallStateTests`
Expected: FAIL — `ClipboardWallState` undefined.

- [ ] **Step 3: Implement**

```swift
import SwiftUI

/// Observable view state for the clipboard wall: the active category tab, the
/// search query, the rendered items, and the keyboard selection index. The
/// window controller pushes items in (after querying the store) and reads the
/// selection back on Enter.
@MainActor
@Observable
final class ClipboardWallState {
    var category: ClipboardHistoryKind?      // nil == "All"
    var query: String = ""
    private(set) var items: [ClipboardHistoryItem] = []
    private(set) var selectedIndex: Int = 0

    /// All category tabs in display order: All, then text/image/file, then the
    /// four legacy kinds. `nil` is the leading "All" tab.
    static let categoryOrder: [ClipboardHistoryKind?] = [
        nil, .text, .image, .file, .screenshot, .color, .ocr, .qrcode,
    ]

    func setItems(_ newItems: [ClipboardHistoryItem]) {
        items = newItems
        selectedIndex = min(selectedIndex, max(0, newItems.count - 1))
        if newItems.isEmpty { selectedIndex = 0 }
    }

    var selectedItem: ClipboardHistoryItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func moveLeft() { selectedIndex = max(0, selectedIndex - 1) }
    func moveRight() { selectedIndex = min(max(0, items.count - 1), selectedIndex + 1) }
    func select(_ index: Int) { if items.indices.contains(index) { selectedIndex = index } }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AnyDoorTests.ClipboardWallStateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/ClipboardWallState.swift Tests/AnyDoorTests/ClipboardWallStateTests.swift
git commit -m "feat(clipboard): add wall view state for category, search, and keyboard selection"
```

---

## Task 11: Card + wall SwiftUI views

**Files:**
- Create: `Sources/AnyDoor/Views/ClipboardCardView.swift`
- Create: `Sources/AnyDoor/Views/ClipboardWallView.swift`

No unit test (pure SwiftUI); verified via build + Task 12 manual run.

- [ ] **Step 1: Implement `ClipboardCardView`**

```swift
import SwiftUI

/// A single clipboard entry rendered as a fixed-size card. Shows the source app
/// icon, kind label, relative time, a kind-specific preview, and a favorite star.
struct ClipboardCardView: View {
    let item: ClipboardHistoryItem
    let isSelected: Bool
    let historyDirectory: URL
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 150, height: 150)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .opacity(item.isReferenceOnly && !ClipboardPasteService.canPaste(item, historyDirectory: historyDirectory) ? 0.5 : 1)
    }

    private var header: some View {
        HStack(spacing: 6) {
            sourceIcon.frame(width: 16, height: 16)
            Text(item.historyKind.map { L($0.titleKey) } ?? "")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text(item.createdAt, style: .relative)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let bundleID = item.sourceBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "doc.on.clipboard").resizable().scaledToFit().foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.historyKind {
        case .text, .ocr, .qrcode:
            Text(item.text ?? item.previewTitle)
                .font(.system(size: 11)).lineLimit(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
        case .color:
            Rectangle().fill(Color(hex: item.colorHex ?? "#000000"))
                .overlay(alignment: .bottomLeading) {
                    Text(item.colorHex ?? "").font(.caption2).foregroundStyle(.white).padding(8)
                }
        case .image, .screenshot:
            if let fileName = item.fileName,
               let img = NSImage(contentsOf: historyDirectory.appendingPathComponent(fileName)) {
                Image(nsImage: img).resizable().scaledToFill().clipped()
            } else {
                Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
            }
        case .file:
            VStack(spacing: 6) {
                Image(systemName: "doc.fill").imageScale(.large)
                Text(item.previewTitle).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
            }.padding(8)
        case .none:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }
}
```

> `Color(hex:)` — if the project lacks this initializer, the color picker /
> `PickColorProvider` area likely has one; search `extension Color` /
> `init(hex`. If none exists, add a small `Color(hex:)` extension in this file.
> Search before adding to avoid a duplicate.

- [ ] **Step 2: Implement `ClipboardWallView`**

```swift
import SwiftUI

/// The card-wall content: category tabs, a search field, a horizontal row of
/// cards, and a keyboard-hint footer. Selection + filtering live in
/// `ClipboardWallState`; the window controller owns querying and paste.
struct ClipboardWallView: View {
    @Bindable var state: ClipboardWallState
    let historyDirectory: URL
    let onSelect: (ClipboardHistoryItem, _ plain: Bool) -> Void
    let onToggleFavorite: (ClipboardHistoryItem) -> Void

    var body: some View {
        VStack(spacing: 10) {
            tabs
            if state.items.isEmpty {
                Spacer()
                LocalizedText(.clipboardEmpty).foregroundStyle(.secondary)
                Spacer()
            } else {
                cards
            }
            hints
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(Array(ClipboardWallState.categoryOrder.enumerated()), id: \.offset) { _, cat in
                let active = state.category == cat
                Button {
                    state.category = cat
                } label: {
                    Text(cat.map { L($0.titleKey) } ?? L(.clipboardCategoryAll))
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(active ? Color.accentColor : Color.secondary.opacity(0.15),
                                    in: Capsule())
                        .foregroundStyle(active ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L(.clipboardSearchPlaceholder), text: $state.query)
                    .textFieldStyle(.plain).frame(width: 140)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        ClipboardCardView(
                            item: item,
                            isSelected: index == state.selectedIndex,
                            historyDirectory: historyDirectory,
                            onToggleFavorite: { onToggleFavorite(item) }
                        )
                        .id(index)
                        .onTapGesture { state.select(index); onSelect(item, false) }
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: state.selectedIndex) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private var hints: some View {
        HStack(spacing: 16) {
            hint("←→", .clipboardHintSelect)
            hint("↵", .clipboardHintCopy)
            hint("⌥↵", .clipboardHintPastePlain)
            hint("space", .clipboardHintPreview)
            hint("⌫", .clipboardHintDelete)
            hint("esc", .clipboardHintClose)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func hint(_ key: String, _ label: L10n.Key) -> some View {
        HStack(spacing: 4) { Text(key).bold(); LocalizedText(label) }
    }
}
```

- [ ] **Step 3: Add L10n keys** (enum + xcstrings)

```
clipboardCategoryAll = "clipboard.category.all"            zh: 全部 / en: All
clipboardSearchPlaceholder = "clipboard.search.placeholder" zh: 搜索… / en: Search…
clipboardHintPastePlain = "clipboard.hint.pastePlain"      zh: 纯文本粘贴 / en: Paste plain
clipboardHintDelete = "clipboard.hint.delete"              zh: 删除 / en: Delete
clipboardHintClose = "clipboard.hint.close"                zh: 关闭 / en: Close
```
(`clipboardEmpty`, `clipboardHintSelect`, `clipboardHintCopy`, `clipboardHintPreview`
already exist — reuse them.)

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/ClipboardCardView.swift Sources/AnyDoor/Views/ClipboardWallView.swift Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(clipboard): add card and card-wall SwiftUI views"
```

---

## Task 12: Wall window controller (bottom panel + keyboard nav + paste)

**Files:**
- Create: `Sources/AnyDoor/Views/ClipboardWallWindowController.swift`
- Modify: `Sources/AnyDoor/AppDelegate.swift` (complete the deferred lines from Task 9)

No unit test (NSPanel + system events); verified by manual run.

- [ ] **Step 1: Implement the controller**

```swift
import AppKit
import QuickLookUI
import SwiftUI

/// Bottom, full-width overlay that hosts the clipboard card wall. Summoned by
/// the clipboard-wall hotkey (via ClipboardWallProvider) or the panel row.
/// Mirrors CommandPaletteWindowController's activation/key-monitor pattern.
@MainActor
final class ClipboardWallWindowController: NSWindowController, NSWindowDelegate, QLPreviewPanelDataSource {
    static let shared = ClipboardWallWindowController()

    /// Set by AppDelegate so paste-from-history can suppress the self-write.
    weak var watcher: ClipboardWatcher?

    private let state = ClipboardWallState()
    private var keyMonitor: Any?
    private var previewURL: URL?

    private var historyDirectory: URL { ClipboardHistoryStore.defaultHistoryDirectory() }

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func toggle() {
        if window?.isVisible == true { close() } else { show() }
    }

    private func show() {
        reloadItems()
        let view = ClipboardWallView(
            state: state,
            historyDirectory: historyDirectory,
            onSelect: { [weak self] item, plain in self?.paste(item, plain: plain) },
            onToggleFavorite: { [weak self] item in
                Task { await ClipboardHistoryStore.shared.toggleFavorite(item); self?.reloadItems() }
            }
        )
        let host = NSHostingView(rootView: view)
        host.frame = window?.contentLayoutRect ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host

        installKeyMonitor()
        positionAtBottom()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Re-query the store using current category/search and push into state.
    private func reloadItems() {
        Task {
            await ClipboardHistoryStore.shared.pruneExpiredAndOverflow(force: false)
            state.setItems(ClipboardHistoryStore.shared.timeline(category: state.category, query: state.query))
        }
    }

    private func positionAtBottom() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let height: CGFloat = 220
        window.setFrame(NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height), display: true)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, window.isVisible else { return false }
        // While the search field is first responder, let typing through (but
        // still honor Esc / arrows when the field is empty is overkill — keep
        // it simple: Esc always closes, arrows always navigate).
        switch event.keyCode {
        case 123: state.moveLeft(); return true          // ←
        case 124: state.moveRight(); return true         // →
        case 36, 76:                                     // ↵ / numpad enter
            if let item = state.selectedItem {
                paste(item, plain: event.modifierFlags.contains(.option))
            }
            return true
        case 49:                                         // space → Quick Look
            toggleQuickLook(); return true
        case 51:                                         // ⌫ → delete selected
            if let item = state.selectedItem {
                Task { await ClipboardHistoryStore.shared.delete(item); self.reloadItems() }
            }
            return true
        case 53: close(); return true                    // esc
        default: return false
        }
    }

    private func paste(_ item: ClipboardHistoryItem, plain: Bool) {
        if !ClipboardPasteService.canPaste(item, historyDirectory: historyDirectory) {
            ToastPresenter.shared.show(.failure(L(.clipboardToastFileMissing)))
            return
        }
        close()
        let pb = NSPasteboard.general
        ClipboardPasteService.writePayload(for: item, asPlainText: plain, to: pb, historyDirectory: historyDirectory)
        watcher?.noteSelfWrite(changeCount: pb.changeCount)
        if !ClipboardPreferences.copyOnly {
            // Defer so focus returns to the prior app before ⌘V is posted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                ClipboardPasteService.synthesizePaste()
            }
        }
    }

    // MARK: - Quick Look (space)
    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            return
        }
        previewURL = quickLookURL(for: state.selectedItem)
        guard previewURL != nil else { return }
        panel.dataSource = self
        panel.makeKeyAndOrderFront(nil)
    }

    private func quickLookURL(for item: ClipboardHistoryItem?) -> URL? {
        guard let item, let kind = item.historyKind else { return nil }
        switch kind {
        case .image, .screenshot:
            guard let f = item.fileName else { return nil }
            return historyDirectory.appendingPathComponent(f)
        case .file:
            if let stored = item.files.first?.storedName { return historyDirectory.appendingPathComponent(stored) }
            if let path = item.files.first?.originalPath { return URL(fileURLWithPath: path) }
            return nil
        default:
            return nil   // text/color preview is already visible on the card
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURL == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURL as NSURL?
    }

    func windowWillClose(_ notification: Notification) { removeKeyMonitor() }
    func windowDidResignKey(_ notification: Notification) {
        // Don't close while Quick Look is the key window.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        close()
    }
}
```

Add L10n keys: `clipboardToastFileMissing = "clipboard.toast.fileMissing"`
(zh: 原文件已不存在，无法粘贴 / en: Original file is no longer available).

> Search/category changes don't auto re-query in this minimal version (the view
> mutates `state.category`/`state.query` but `reloadItems` runs on show). Wire a
> lightweight refresh: add `.onChange(of: state.category)` and
> `.onChange(of: state.query)` in `ClipboardWallView.body` calling a closure
> `onFilterChange` that the controller sets to `reloadItems`. Add that closure
> param to `ClipboardWallView` and pass `{ [weak self] in self?.reloadItems() }`
> from `show()`. (Keep it; without it, tabs/search won't refilter live.)

- [ ] **Step 2: Complete the deferred AppDelegate wiring from Task 9**

Add the provider registration and the watcher↔controller link (Task 9 Steps 2/5):
```swift
// in providers array:
ClipboardWallProvider(),
// after starting the watcher:
ClipboardWallWindowController.shared.watcher = watcher
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Manual verification**

Run: `swift run AnyDoor` (grant Accessibility if prompted).
- Copy text in another app → press ⌘⇧V → wall appears at the bottom with the entry.
- ←→ moves selection; ↵ pastes into the previously focused app (focus a text field first).
- ⌥↵ pastes plain text (verify formatting dropped from a rich source like a web page).
- Copy an image and a file → confirm they appear under the Image / File tabs.
- space on an image/file card → Quick Look preview opens; space again closes.
- ★ toggles favorite; ⌫ deletes; esc closes.
- Toggle "copy only" in Settings → ↵ now only copies (no auto-paste).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/ClipboardWallWindowController.swift Sources/AnyDoor/Views/ClipboardWallView.swift Sources/AnyDoor/AppDelegate.swift Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(clipboard): add bottom card-wall window with keyboard nav, paste, and quick look"
```

---

## Task 13: Full suite + changelog

**Files:**
- Modify: `CHANGELOG.md` (follow the existing entry style)

- [ ] **Step 1: Run the whole test suite**

Run: `swift test`
Expected: all tests pass (existing + new clipboard tests).

- [ ] **Step 2: Add a changelog entry**

Mirror the format of the most recent entries in `CHANGELOG.md`. Summarize: add a
Paste-style clipboard history (background capture of text/images/files, bottom
card wall via ⌘⇧V, rich/plain paste, favorites, search, retention settings).

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog entry for clipboard history"
```

---

## Self-Review Notes

- **Spec coverage:** capture (T2/T7), text/image/file kinds (T1/T3), unified
  timeline + tabs (T4/T10/T11), auto-paste + copy-only + plain modifier
  (T6/T8/T12), favorites + delete + clear-all (T4, existing), privacy filter
  (T2/T7), file copy + size ceiling + reference-only (T3), retention +
  favorite-exempt prune (T5/T8), hotkey + panel integration + ⌘⇧V seed
  (T9), Quick Look on space (T12). **Deferred (noted in T8):** app-exclusion
  list editor UI and disk-budget UI — preference keys + watcher honoring exist;
  only the editor surface is deferred. Out of scope per spec: pinboards, iCloud
  sync, paste stack.
- **Ordering caveat:** Tasks 9 and 12 are interdependent (provider/AppDelegate
  reference the controller). T9 Step 2/5 and the controller-link line in T9
  Step 4 are explicitly marked to land with/after T12. A subagent executing
  strictly in order should implement T9 Steps 1/3/4(store+watcher only), then
  T10–12, then close T9 Steps 2/5.
- **Type consistency:** `record(_:source:)`, `ClipboardSource`,
  `CapturedClipboard`, `timeline(category:query:)`, `toggleFavorite`, `delete`,
  `ClipboardPasteService.writePayload/canPaste/synthesizePaste`,
  `ClipboardWatcher.poll/start/noteSelfWrite`, `ClipboardWallState`,
  `ClipboardWallWindowController.shared.toggle/.watcher` are used consistently
  across tasks.
