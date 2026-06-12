# Clipboard Text Preview (Space) + Card Context Menu with Edit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pressing Space on a text-bearing clipboard-wall item opens a floating read-only text preview; right-clicking a card shows a context menu (Edit / Copy / Favorite / Delete), where Edit opens the same floating panel in editable mode and persists changes.

**Architecture:** A new singleton `ClipboardTextWindow` (modeled on `ScreenshotPreviewWindow`) hosts a SwiftUI panel in two modes: preview (panel never becomes key; wall keeps keyboard) and edit (key-capable non-activating panel embedding the existing `PlainTextEditor`). `ClipboardWallWindowController` routes Space/Esc/arrows to it and gains an exemption (like Quick Look) so the wall isn't dismissed while the panel is up. A new `ClipboardHistoryStore.updateText` persists edits and clears the stale rich payload.

**Tech Stack:** Swift 6.2 strict concurrency, SwiftUI + AppKit NSPanel, SwiftData, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-12-clipboard-text-preview-edit-design.md`

**File map:**

| File | Change |
|---|---|
| `Sources/AnyDoor/Utilities/L10n.swift` | Add 11 `L10n.Key` cases |
| `Sources/AnyDoor/Resources/Localizable.xcstrings` | Add 11 entries (en + zh-Hans) |
| `Sources/AnyDoor/Models/ClipboardHistoryItem.swift` | Add `ClipboardHistoryKind.isTextBearing` |
| `Sources/AnyDoor/Services/ClipboardHistoryStore.swift` | Add `updateText(_:newText:)` |
| `Sources/AnyDoor/Views/ClipboardTextWindow.swift` | **New**: window + panel subclass + `ClipboardTextPanelModel` + `ClipboardTextPanelView` |
| `Sources/AnyDoor/Views/ClipboardWallWindowController.swift` | Space routing, key routing, resign-key/outside-click guards, context-menu actions |
| `Sources/AnyDoor/Views/ClipboardWallView.swift` | Pass-through `onEdit` / `onCopy` / `onDelete` |
| `Sources/AnyDoor/Views/ClipboardCardView.swift` | `.contextMenu` + optional callbacks |
| `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift` | `updateText` tests |
| `Tests/AnyDoorTests/ClipboardTextPanelModelTests.swift` | **New**: model behavior tests |

Conventions that apply to every task: all code comments in English; UI strings only via `L10n`; commit messages follow Conventional Commits, no Co-Authored-By / generation signatures, never use a literal `@` in commit text (write "the Observable macro", not the attribute symbol).

---

### Task 1: Localization keys

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift` (clipboard key block, around lines 77–99)
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the enum cases**

In `L10n.swift`, the clipboard keys are grouped alphabetically (`clipboardHintClose` is at line 80). Insert these cases immediately **before** `case clipboardHintClose = "clipboard.hint.close"`:

```swift
        case clipboardActionCopy = "clipboard.action.copy"
        case clipboardActionDelete = "clipboard.action.delete"
        case clipboardActionEdit = "clipboard.action.edit"
        case clipboardActionFavorite = "clipboard.action.favorite"
        case clipboardActionUnfavorite = "clipboard.action.unfavorite"
        case clipboardEditCancel = "clipboard.edit.cancel"
        case clipboardEditDiscard = "clipboard.edit.discard"
        case clipboardEditDiscardPrompt = "clipboard.edit.discardPrompt"
        case clipboardEditKeepEditing = "clipboard.edit.keepEditing"
        case clipboardEditSave = "clipboard.edit.save"
        case clipboardEditTitle = "clipboard.edit.title"
```

- [ ] **Step 2: Add the catalog entries**

The `.xcstrings` file is JSON (2-space indent, keys sorted, entries shaped exactly like the existing `"clipboard.preview.close"` entry). Run:

```bash
python3 - <<'EOF'
import json
path = 'Sources/AnyDoor/Resources/Localizable.xcstrings'
with open(path) as f:
    catalog = json.load(f)
entries = {
    "clipboard.action.copy": ("Copy", "复制"),
    "clipboard.action.delete": ("Delete", "删除"),
    "clipboard.action.edit": ("Edit", "编辑"),
    "clipboard.action.favorite": ("Favorite", "收藏"),
    "clipboard.action.unfavorite": ("Unfavorite", "取消收藏"),
    "clipboard.edit.cancel": ("Cancel", "取消"),
    "clipboard.edit.discard": ("Discard", "放弃修改"),
    "clipboard.edit.discardPrompt": ("Discard unsaved changes?", "放弃未保存的修改？"),
    "clipboard.edit.keepEditing": ("Keep Editing", "继续编辑"),
    "clipboard.edit.save": ("Save", "保存"),
    "clipboard.edit.title": ("Edit Text", "编辑文本"),
}
for key, (en, zh) in entries.items():
    catalog["strings"][key] = {
        "extractionState": "manual",
        "localizations": {
            "en": {"stringUnit": {"state": "translated", "value": en}},
            "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
        },
    }
with open(path, "w") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
EOF
```

- [ ] **Step 3: Sanity-check the diff**

Run: `git diff --stat Sources/AnyDoor/Resources/Localizable.xcstrings`

Expected: roughly +190/−small. If the diff shows thousands of changed lines (re-serialization churn of unrelated entries), revert (`git checkout -- Sources/AnyDoor/Resources/Localizable.xcstrings`) and instead insert the 11 entries by hand with the Edit tool, copying the exact JSON shape of `"clipboard.preview.close"`.

- [ ] **Step 4: Run the localization coverage tests**

Run: `swift test --filter LocalizationCoverageTests`
Expected: PASS (the suite asserts every `L10n.Key` case has en + zh-Hans entries; a missing entry fails here).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(clipboard): add localization keys for card menu and text editor"
```

---

### Task 2: `isTextBearing` + `ClipboardHistoryStore.updateText`

**Files:**
- Modify: `Sources/AnyDoor/Models/ClipboardHistoryItem.swift` (the `ClipboardHistoryKind` enum, lines 4–24)
- Modify: `Sources/AnyDoor/Services/ClipboardHistoryStore.swift` (next to `toggleFavorite`, line 295)
- Test: `Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `ClipboardHistoryStoreTests` (it already has `makeContainer()` and the in-memory `ModelConfiguration` pattern):

```swift
    func testUpdateTextRewritesPreviewAndClearsRichPayload() async throws {
        let container = try makeContainer()
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        let created = Date(timeIntervalSinceReferenceDate: 50)
        let item = ClipboardHistoryItem(
            kind: .text,
            text: "old text",
            previewTitle: "old text",
            createdAt: created,
            richData: Data([0x01]),
            richType: "public.rtf"
        )
        container.mainContext.insert(item)
        try container.mainContext.save()

        await store.updateText(item, newText: "new first line\nsecond line")

        XCTAssertEqual(item.text, "new first line\nsecond line")
        XCTAssertEqual(item.previewTitle, "new first line")
        XCTAssertNotNil(item.previewSubtitle)
        // The stale rich payload would win on paste and resurrect the pre-edit
        // content, so editing must clear it.
        XCTAssertNil(item.richData)
        XCTAssertNil(item.richType)
        // The card keeps its position in the wall.
        XCTAssertEqual(item.createdAt, created)
        // The per-kind cache reflects the edit.
        XCTAssertEqual(store.items(for: .text).map(\.text), ["new first line\nsecond line"])
    }

    func testTextBearingKinds() {
        XCTAssertTrue(ClipboardHistoryKind.text.isTextBearing)
        XCTAssertTrue(ClipboardHistoryKind.ocr.isTextBearing)
        XCTAssertTrue(ClipboardHistoryKind.qrcode.isTextBearing)
        XCTAssertFalse(ClipboardHistoryKind.color.isTextBearing)
        XCTAssertFalse(ClipboardHistoryKind.image.isTextBearing)
        XCTAssertFalse(ClipboardHistoryKind.screenshot.isTextBearing)
        XCTAssertFalse(ClipboardHistoryKind.file.isTextBearing)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ClipboardHistoryStoreTests`
Expected: BUILD FAILURE — `value of type 'ClipboardHistoryStore' has no member 'updateText'` and `has no member 'isTextBearing'`. (A compile error is this step's "failing test".)

- [ ] **Step 3: Implement**

In `Sources/AnyDoor/Models/ClipboardHistoryItem.swift`, add to `ClipboardHistoryKind` (after the `titleKey` computed property, before the enum's closing brace):

```swift
    /// Kinds whose payload is a plain string in `text` — the ones the floating
    /// text panel can preview and edit.
    var isTextBearing: Bool {
        switch self {
        case .text, .ocr, .qrcode: return true
        case .color, .screenshot, .image, .file: return false
        }
    }
```

In `Sources/AnyDoor/Services/ClipboardHistoryStore.swift`, add directly after `toggleFavorite` (line 300):

```swift
    /// Persist an edited text payload for a text-bearing item. The rich payload
    /// is cleared — it no longer matches the edited plain text and would
    /// otherwise win on paste. `createdAt` is preserved so the card keeps its
    /// position in the wall.
    func updateText(_ item: ClipboardHistoryItem, newText: String) async {
        guard let container = modelContainer else { return }
        item.text = newText
        item.previewTitle = Self.previewTitle(for: newText)
        item.previewSubtitle = Self.textSubtitle(for: newText)
        item.richData = nil
        item.richType = nil
        try? container.mainContext.save()
        if let kind = item.historyKind { await reload(kind: kind) }
    }
```

(`previewTitle(for:)` / `textSubtitle(for:)` are private statics in the same file — lines 522/527 — so they're accessible.)

- [ ] **Step 4: Run the tests again**

Run: `swift test --filter ClipboardHistoryStoreTests`
Expected: PASS (all tests in the suite, including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/ClipboardHistoryItem.swift Sources/AnyDoor/Services/ClipboardHistoryStore.swift Tests/AnyDoorTests/ClipboardHistoryStoreTests.swift
git commit -m "feat(clipboard): add updateText store mutation and isTextBearing"
```

---

### Task 3: `ClipboardTextWindow` (panel + model + view)

**Files:**
- Create: `Sources/AnyDoor/Views/ClipboardTextWindow.swift`
- Test: `Tests/AnyDoorTests/ClipboardTextPanelModelTests.swift` (new)

- [ ] **Step 1: Write the failing model tests**

Create `Tests/AnyDoorTests/ClipboardTextPanelModelTests.swift`:

```swift
import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardTextPanelModelTests: XCTestCase {
    private func makeItem(text: String) -> ClipboardHistoryItem {
        ClipboardHistoryItem(kind: .text, text: text, previewTitle: text)
    }

    func testCleanCloseDismissesWithoutConfirmation() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }

        model.requestClose()

        XCTAssertTrue(dismissed)
        XCTAssertFalse(model.showDiscardConfirm)
    }

    func testDirtyCloseShowsConfirmationInsteadOfDismissing() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.text = "hello edited"

        model.requestClose()

        XCTAssertFalse(dismissed)
        XCTAssertTrue(model.showDiscardConfirm)
    }

    func testEscOnConfirmationKeepsEditing() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.text = "hello edited"
        model.requestClose()

        // A second Esc while the overlay is up means "keep editing".
        model.requestClose()

        XCTAssertFalse(dismissed)
        XCTAssertFalse(model.showDiscardConfirm)
    }

    func testDiscardDismisses() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: true)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.text = "hello edited"
        model.requestClose()

        model.discard()

        XCTAssertTrue(dismissed)
    }

    func testCanSaveRejectsWhitespaceOnlyText() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: true)
        model.text = "   \n\t"
        XCTAssertFalse(model.canSave)
        model.text = "ok"
        XCTAssertTrue(model.canSave)
    }

    func testPreviewModeIsNeverDirty() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "hello"), isEditable: false)
        model.text = "mutated"
        XCTAssertFalse(model.isDirty)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.requestClose()
        XCTAssertTrue(dismissed)
    }

    func testReplaceSwapsContentAndResetsBaseline() {
        let model = ClipboardTextPanelModel(item: makeItem(text: "first"), isEditable: false)
        model.replace(item: makeItem(text: "second"))
        XCTAssertEqual(model.text, "second")
        XCTAssertFalse(model.isDirty)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ClipboardTextPanelModelTests`
Expected: BUILD FAILURE — `cannot find 'ClipboardTextPanelModel' in scope`.

- [ ] **Step 3: Create `ClipboardTextWindow.swift`**

Create `Sources/AnyDoor/Views/ClipboardTextWindow.swift` with this exact content:

```swift
import AppKit
import SwiftUI

/// Floating panel that previews (read-only) or edits (writable) the text of a
/// text-bearing clipboard history item. Preview mirrors ScreenshotPreviewWindow:
/// borderless, non-activating, never key — the wall keeps keyboard focus and
/// drives it (Space/Esc close, arrows follow the selection). Edit mode swaps in
/// a key-capable panel so the embedded NSTextView can take keystrokes; it closes
/// only explicitly (Save / Cancel / Esc with a dirty check), never on outside
/// clicks, so a stray click can't throw away an in-progress edit.
@MainActor
final class ClipboardTextWindow {
    static let shared = ClipboardTextWindow()

    private var panel: KeyableTextPanel?
    private var model: ClipboardTextPanelModel?
    private var mouseMonitors: [Any] = []
    /// Invoked after the panel closes; the wall re-takes key status here.
    private var onClose: (() -> Void)?

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }
    var isEditing: Bool { isVisible && model?.isEditable == true }
    var isPreviewVisible: Bool { isVisible && model?.isEditable == false }

    func showPreview(item: ClipboardHistoryItem) {
        // Already previewing: swap the content in place (arrow-key follow).
        if isPreviewVisible, let model {
            model.replace(item: item)
            return
        }
        present(item: item, editable: false, onClose: nil)
    }

    func showEditor(item: ClipboardHistoryItem, onClose: (() -> Void)? = nil) {
        present(item: item, editable: true, onClose: onClose)
    }

    /// Esc / Cancel: discard-confirm when dirty, straight close otherwise.
    func requestClose() { model?.requestClose() }

    /// Save shortcut (the wall's key monitor routes ⌘S here while editing).
    func saveRequested() { model?.saveIfPossible() }

    func close() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
        panel?.orderOut(nil)
        panel = nil
        model = nil
        let callback = onClose
        onClose = nil
        callback?()
    }

    private func present(item: ClipboardHistoryItem, editable: Bool, onClose: (() -> Void)?) {
        close()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let rect = NSRect(
            x: visible.midX - visible.width * 0.3,
            y: visible.midY - visible.height * 0.3,
            width: visible.width * 0.6,
            height: visible.height * 0.6
        )

        let p = KeyableTextPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.allowsKey = editable
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        let model = ClipboardTextPanelModel(item: item, isEditable: editable)
        model.onDismiss = { [weak self] in self?.close() }
        self.model = model
        self.onClose = onClose

        let hosting = NSHostingView(rootView: ClipboardTextPanelView(model: model))
        hosting.frame = NSRect(origin: .zero, size: rect.size)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        panel = p

        if editable {
            // The editor must be key to take keystrokes; .nonactivatingPanel
            // keeps the previously active app active regardless.
            p.makeKeyAndOrderFront(nil)
            // Park the caret in the text view once the hosting view has laid out.
            DispatchQueue.main.async { [weak self] in
                guard let self, let content = self.panel?.contentView else { return }
                _ = Self.focusTextView(in: content, window: self.panel)
            }
        } else {
            p.orderFrontRegardless()
            installPreviewMouseMonitors()
        }
    }

    /// Preview only: any mouse-down outside the panel closes it (clicks inside
    /// the wall included, so picking a card by mouse drops the stale preview).
    private func installPreviewMouseMonitors() {
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            let inside = MainActor.assumeIsolated { event.window === self.panel }
            if !inside { MainActor.assumeIsolated { self.close() } }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        mouseMonitors = [local, global].compactMap { $0 }
    }

    private static func focusTextView(in view: NSView, window: NSWindow?) -> Bool {
        if let textView = view as? NSTextView, textView.isEditable {
            window?.makeFirstResponder(textView)
            return true
        }
        for subview in view.subviews where focusTextView(in: subview, window: window) {
            return true
        }
        return false
    }
}

/// Borderless panels refuse key status by default; the editor needs it for
/// typing while the read-only preview must NOT take it (the wall keeps keyboard
/// control in preview mode), hence the runtime flag rather than a constant.
private final class KeyableTextPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// View state for the floating text panel. Pure logic (dirty tracking, the
/// discard-confirmation flow, save gating) so it is unit-testable without UI.
@MainActor
@Observable
final class ClipboardTextPanelModel {
    private(set) var item: ClipboardHistoryItem
    let isEditable: Bool
    var text: String
    private var originalText: String
    var showDiscardConfirm = false
    var onDismiss: () -> Void = {}

    init(item: ClipboardHistoryItem, isEditable: Bool) {
        self.item = item
        self.isEditable = isEditable
        let value = item.text ?? ""
        self.text = value
        self.originalText = value
    }

    var isDirty: Bool { isEditable && text != originalText }
    var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Preview-follow: swap to another item without recreating the panel.
    func replace(item: ClipboardHistoryItem) {
        self.item = item
        let value = item.text ?? ""
        text = value
        originalText = value
    }

    /// Esc / close button. A second request while the overlay is up means
    /// "keep editing" (Esc backs out of the confirmation, not the editor).
    func requestClose() {
        if showDiscardConfirm {
            showDiscardConfirm = false
            return
        }
        if isDirty {
            showDiscardConfirm = true
        } else {
            onDismiss()
        }
    }

    func saveIfPossible() {
        guard isEditable, canSave else { return }
        let item = item
        let newText = text
        Task { await ClipboardHistoryStore.shared.updateText(item, newText: newText) }
        onDismiss()
    }

    func discard() { onDismiss() }
}

struct ClipboardTextPanelView: View {
    @Bindable var model: ClipboardTextPanelModel

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                PlainTextEditor(text: $model.text, isEditable: model.isEditable)
                    .padding(8)
                Divider()
                footer
            }
            if model.showDiscardConfirm { discardOverlay }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        HStack {
            LocalizedText(model.isEditable ? .clipboardEditTitle : .clipboardPreviewTitle)
                .font(.headline)
            Spacer()
            Button { model.requestClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .help(L(.clipboardPreviewClose))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Text(metaText)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.isEditable {
                Button { model.requestClose() } label: {
                    LocalizedText(.clipboardEditCancel)
                }
                Button { model.saveIfPossible() } label: {
                    LocalizedText(.clipboardEditSave)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Mirrors the card subtitle: line count for multi-line, else characters.
    private var metaText: String {
        let lineCount = model.text.split(whereSeparator: \.isNewline).count
        return lineCount > 1 ? L(.clipboardTextLines, lineCount) : L(.clipboardTextChars, model.text.count)
    }

    private var discardOverlay: some View {
        VStack(spacing: 14) {
            LocalizedText(.clipboardEditDiscardPrompt)
                .font(.headline)
            HStack(spacing: 10) {
                Button { model.showDiscardConfirm = false } label: {
                    LocalizedText(.clipboardEditKeepEditing)
                }
                Button(role: .destructive) { model.discard() } label: {
                    LocalizedText(.clipboardEditDiscard)
                }
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
    }
}
```

- [ ] **Step 4: Run the model tests**

Run: `swift test --filter ClipboardTextPanelModelTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/ClipboardTextWindow.swift Tests/AnyDoorTests/ClipboardTextPanelModelTests.swift
git commit -m "feat(clipboard): add floating text preview/edit panel"
```

---

### Task 4: Wall controller integration (Space / Esc / arrows / lifecycle guards)

**Files:**
- Modify: `Sources/AnyDoor/Views/ClipboardWallWindowController.swift`

All line numbers refer to the file as of commit `14ada9c`.

- [ ] **Step 1: Make wall dismissal close the text panel**

In `dismiss(restoreFocus:completion:)` (line 135), add one line at the very top of the body, before the `guard`:

```swift
    private func dismiss(restoreFocus: Bool, completion: (@Sendable () -> Void)? = nil) {
        // The floating text panel has no life of its own once the wall goes away.
        ClipboardTextWindow.shared.close()
        guard !isAnimating, let window, window.isVisible, let screen = NSScreen.main else {
```

- [ ] **Step 2: Exempt the text panel in the resign-key handler**

Replace `windowDidResignKey` (lines 367–374) with:

```swift
    func windowDidResignKey(_ notification: Notification) {
        // Don't close while Quick Look or the floating text panel is up — the
        // text editor takes key status while the wall stays open behind it.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        if ClipboardTextWindow.shared.isVisible { return }
        // Ignore the resign that the slide-out animation itself triggers.
        guard !isAnimating else { return }
        // A click elsewhere already moved focus; don't yank it back.
        dismiss(restoreFocus: false)
    }
```

- [ ] **Step 3: Protect an in-progress edit from outside clicks**

In `installMonitors()` (line 202), replace the `globalMouseMonitor` closure body with:

```swift
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
                // Don't throw away an in-progress edit on a stray outside click.
                if ClipboardTextWindow.shared.isEditing { return }
                self.dismiss(restoreFocus: false)
            }
        }
```

- [ ] **Step 4: Route keys to the text panel and sync the preview**

Replace the whole `handle(_:)` method (lines 246–286) with:

```swift
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, window.isVisible else { return false }
        if let consumed = routeToTextWindow(event) { return consumed }
        let inputMode = state.isSearchFocused
        switch event.keyCode {
        case 53:                                         // esc — staged exit
            if state.query.isEmpty {
                // Nothing to step back through: close outright, in either mode.
                dismiss(restoreFocus: true)
            } else if inputMode {
                // A non-empty query clears first, leaving the field focused.
                state.query = ""; searchField?.stringValue = ""
            } else {
                // Card navigation over a search → return focus to edit/clear it.
                state.isSearchFocused = true
            }
            return true
        case 36, 76:                                     // ↵ / numpad enter
            if let item = state.selectedItem {
                paste(item, plain: event.modifierFlags.contains(.option))
            }
            return true
        case 123:                                        // ←
            if inputMode { return false }                // move the text caret
            state.moveLeft(); syncTextPreview(); return true
        case 124:                                        // →
            if inputMode { return false }                // field delegate may exit
            state.moveRight(); syncTextPreview(); return true
        case 49:                                         // space
            if inputMode { return false }                // insert a space
            togglePreview(); return true
        case 51:                                         // ⌫
            if inputMode { return false }                // delete a character
            if let item = state.selectedItem {
                // The preview would otherwise keep showing the deleted item.
                if ClipboardTextWindow.shared.isPreviewVisible { ClipboardTextWindow.shared.close() }
                Task { await ClipboardHistoryStore.shared.delete(item) }
            }
            return true
        default:
            if inputMode { return false }                // field inserts / composes
            return focusSearchOnType(event)
        }
    }

    /// Keys claimed by the floating text panel while it is up. Returns nil when
    /// the event should flow to the wall's normal handling instead.
    private func routeToTextWindow(_ event: NSEvent) -> Bool? {
        let textWindow = ClipboardTextWindow.shared
        if textWindow.isEditing {
            if event.keyCode == 53 {                     // esc → dirty-checked close
                textWindow.requestClose(); return true
            }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
                textWindow.saveRequested(); return true  // ⌘S → save
            }
            // Everything else (typing, ⌘Z, arrows…) belongs to the key editor.
            return false
        }
        if textWindow.isPreviewVisible {
            switch event.keyCode {
            case 53, 49:                                 // esc / space close it
                textWindow.close(); return true
            default:
                return nil                               // arrows etc. fall through
            }
        }
        return nil
    }
```

- [ ] **Step 5: Route Space by kind and add the preview-follow helper**

In the `// MARK: - Quick Look (space)` section (line 326), add these two methods **above** `toggleQuickLook()`, leaving `toggleQuickLook` / `quickLookURL` themselves unchanged:

```swift
    /// Space: text-bearing kinds open the floating text panel; image/screenshot/
    /// file go through system Quick Look; color has no preview (the card already
    /// shows the value).
    private func togglePreview() {
        guard let item = state.selectedItem else { return }
        if item.historyKind?.isTextBearing == true {
            if ClipboardTextWindow.shared.isPreviewVisible {
                ClipboardTextWindow.shared.close()
            } else {
                ClipboardTextWindow.shared.showPreview(item: item)
            }
            return
        }
        toggleQuickLook()
    }

    /// Keep an open text preview in step with the keyboard selection (Finder
    /// Quick Look behavior). Closes it when the selection leaves text kinds.
    private func syncTextPreview() {
        guard ClipboardTextWindow.shared.isPreviewVisible else { return }
        if let item = state.selectedItem, item.historyKind?.isTextBearing == true {
            ClipboardTextWindow.shared.showPreview(item: item)
        } else {
            ClipboardTextWindow.shared.close()
        }
    }
```

- [ ] **Step 6: Build and run the full test suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Views/ClipboardWallWindowController.swift
git commit -m "feat(clipboard): open text preview from space in the card wall"
```

---

### Task 5: Card context menu (Edit / Copy / Favorite / Delete)

**Files:**
- Modify: `Sources/AnyDoor/Views/ClipboardCardView.swift`
- Modify: `Sources/AnyDoor/Views/ClipboardWallView.swift:94-100`
- Modify: `Sources/AnyDoor/Views/ClipboardWallWindowController.swift:162-176`

- [ ] **Step 1: Add the callbacks and context menu to the card**

In `ClipboardCardView.swift`, replace the property block (lines 7–13) with:

```swift
    let item: ClipboardHistoryItem
    let isSelected: Bool
    let historyDirectory: URL
    /// The text line that matched the active search, when the match falls below
    /// the visible first line. Shown so a search hit is visible on the card.
    var matchSnippet: String? = nil
    let onToggleFavorite: () -> Void
    /// Context-menu actions; nil hides the matching menu item (previews/tests).
    var onEdit: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
```

Then chain `.contextMenu` onto the card root, after the `.opacity(...)` modifier (line 31):

```swift
        .opacity(item.isReferenceOnly && !ClipboardPasteService.canPaste(item, historyDirectory: historyDirectory) ? 0.5 : 1)
        .contextMenu { contextMenuItems }
```

And add the builder as a new private member (e.g. after `body`):

```swift
    /// Right-click menu. Edit only appears for text-bearing kinds; Favorite
    /// flips its label with the current state.
    @ViewBuilder
    private var contextMenuItems: some View {
        if item.historyKind?.isTextBearing == true, let onEdit {
            Button(action: onEdit) {
                Label { LocalizedText(.clipboardActionEdit) } icon: { Image(systemName: "pencil") }
            }
        }
        if let onCopy {
            Button(action: onCopy) {
                Label { LocalizedText(.clipboardActionCopy) } icon: { Image(systemName: "doc.on.doc") }
            }
        }
        Button(action: onToggleFavorite) {
            Label {
                LocalizedText(item.isFavorite ? .clipboardActionUnfavorite : .clipboardActionFavorite)
            } icon: {
                Image(systemName: item.isFavorite ? "star.slash" : "star")
            }
        }
        if let onDelete {
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label { LocalizedText(.clipboardActionDelete) } icon: { Image(systemName: "trash") }
            }
        }
    }
```

- [ ] **Step 2: Pass the callbacks through the wall view**

In `ClipboardWallView.swift`, add three properties after `onToggleFavorite` (line 18) and **before** `registerSearchField` (so the memberwise-init order keeps `registerSearchField` last with its default):

```swift
    let onToggleFavorite: (ClipboardHistoryItem) -> Void
    /// Context-menu actions, injected by the window controller.
    let onEdit: (ClipboardHistoryItem) -> Void
    let onCopy: (ClipboardHistoryItem) -> Void
    let onDelete: (ClipboardHistoryItem) -> Void
```

(The `onToggleFavorite` line is shown for placement only — it already exists; add the three below it.)

Then in `cards(_:)`, replace the `ClipboardCardView(...)` call (lines 94–100) with:

```swift
                        ClipboardCardView(
                            item: item,
                            isSelected: index == state.selectedIndex,
                            historyDirectory: historyDirectory,
                            matchSnippet: ClipboardSearch.matchSnippet(for: item, query: state.query),
                            onToggleFavorite: { onToggleFavorite(item) },
                            // Select the card the user right-clicked so the
                            // action visibly applies to it.
                            onEdit: { state.select(index); onEdit(item) },
                            onCopy: { state.select(index); onCopy(item) },
                            onDelete: { state.select(index); onDelete(item) }
                        )
```

- [ ] **Step 3: Wire the controller**

In `ClipboardWallWindowController.makeWallView()` (line 162), replace the `ClipboardWallView(...)` construction with:

```swift
        let view = ClipboardWallView(
            state: state,
            historyDirectory: historyDirectory,
            onSelect: { [weak self] item, plain in self?.paste(item, plain: plain) },
            onToggleFavorite: { item in
                Task { await ClipboardHistoryStore.shared.toggleFavorite(item) }
            },
            onEdit: { [weak self] item in self?.beginEdit(item) },
            onCopy: { [weak self] item in self?.copyWithoutPasting(item) },
            onDelete: { item in
                Task { await ClipboardHistoryStore.shared.delete(item) }
            },
            registerSearchField: { [weak self] field in self?.searchField = field }
        )
```

And add the two new methods (e.g. right after `paste(_:plain:)`, line 324):

```swift
    // MARK: - Context-menu actions

    /// "Edit" from a card's context menu: open the floating text editor. The
    /// wall stays open behind it (windowDidResignKey exempts the text panel);
    /// key status returns to the wall when the editor closes.
    private func beginEdit(_ item: ClipboardHistoryItem) {
        guard item.historyKind?.isTextBearing == true else { return }
        ClipboardTextWindow.shared.showEditor(item: item) { [weak self] in
            self?.window?.makeKey()
        }
    }

    /// "Copy" from a card's context menu: write the payload to the pasteboard
    /// without pasting or dismissing the wall.
    private func copyWithoutPasting(_ item: ClipboardHistoryItem) {
        guard ClipboardPasteService.canPaste(item, historyDirectory: historyDirectory) else {
            ToastPresenter.shared.show(.failure(L(.clipboardToastFileMissing)))
            return
        }
        let pb = NSPasteboard.general
        ClipboardPasteService.writePayload(for: item, asPlainText: false, to: pb, historyDirectory: historyDirectory)
        // Suppress the watcher so the re-copy isn't captured as a duplicate.
        watcher?.noteSelfWrite(changeCount: pb.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }
```

- [ ] **Step 4: Build and run the full test suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/ClipboardCardView.swift Sources/AnyDoor/Views/ClipboardWallView.swift Sources/AnyDoor/Views/ClipboardWallWindowController.swift
git commit -m "feat(clipboard): add card context menu with edit, copy, delete"
```

---

### Task 6: Manual verification

**Files:** none (verification only).

- [ ] **Step 1: Launch the dev build**

Run: `swift run AnyDoor` (needs Accessibility granted to the `swift run` identity; if hotkeys don't fire, grant it in System Settings → Privacy & Security → Accessibility).

- [ ] **Step 2: Walk the checklist**

Copy a multi-line text snippet, then open the clipboard wall (its hotkey or the panel row) and verify:

1. **Space preview**: select a text card, press Space → floating read-only panel with the full text; Space or Esc closes it (the wall stays open); pressing Esc again closes the wall.
2. **Preview follows selection**: with the preview open, press ←/→ → content swaps to the newly selected text card; landing on an image card closes the text preview; Space on the image card still opens system Quick Look.
3. **Context menu**: right-click a text card → Edit / Copy / Favorite / Delete all present; on an image card → no Edit entry.
4. **Copy**: choose Copy → toast "已复制到剪贴板", wall stays open, no new duplicate card appears.
5. **Edit + save**: choose Edit → editor opens with the caret in the text, type a change, press ⌘S (also try the Save button on a second pass) → panel closes, the card shows the new text, the card keeps its position; paste the item (Return) → the **edited plain** text is pasted (not the old rich content).
6. **Dirty Esc**: Edit, type a change, press Esc → "放弃未保存的修改？" overlay; Esc again → back to editing; Esc → overlay → 放弃修改 → closes without saving.
7. **Clean Esc**: Edit, change nothing, Esc → closes immediately; the wall is still open and arrow keys work (key status returned).
8. **Edit protection**: while editing, click on another app → the editor and wall stay up (no data loss).
9. **Empty save**: select-all + delete in the editor → Save button disabled; ⌘S does nothing.
10. **Favorite/Unfavorite + Delete** from the menu behave as their existing buttons/keys.
11. Switch language in Settings (中文 ⇄ English) → menu items and panel buttons re-render in the new language.

- [ ] **Step 3: Record any deviations**

If a checklist item fails, stop and fix before claiming completion (re-run the relevant earlier task's tests after each fix).
