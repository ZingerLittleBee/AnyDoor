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
    /// Set by the wall controller: how to open the editor for an item. The
    /// preview's "e" key / header button route through this so editing always
    /// goes down the same path as the card's context menu.
    var onEditRequest: ((ClipboardHistoryItem) -> Void)?

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }
    var isEditing: Bool { isVisible && model?.isEditable == true }
    var isPreviewVisible: Bool { isVisible && model?.isEditable == false }

    /// Whether `window` is the floating text panel (the wall's scroll monitor
    /// uses this to leave scroll events over the panel alone).
    func owns(_ window: NSWindow?) -> Bool {
        window != nil && window === panel
    }

    func showPreview(item: ClipboardHistoryItem) {
        // Never clobber an active edit; the editor closes only explicitly.
        guard !isEditing else { return }
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

    /// Steps aside for a modal flow. A clean editor or read-only preview closes
    /// outright (returns true so the caller can proceed). A dirty editor gets
    /// the dirty-checked close prompt and returns false so the caller must wait
    /// for the user to resolve the edit before opening the modal.
    func yieldToModal() -> Bool {
        if isEditing, model?.isDirty == true {
            requestClose()   // dirty-checked; user resolves the edit first
            return false
        }
        close()              // a clean editor or read-only preview steps aside
        return true
    }

    /// Save shortcut (the wall's key monitor routes ⌘S here while editing).
    func saveRequested() { model?.saveIfPossible() }

    /// Swap a read-only preview for the editor on the same item ("e" key or
    /// the header's edit button). No-op outside preview mode.
    func requestEditFromPreview() {
        guard isPreviewVisible, let item = model?.item else { return }
        onEditRequest?(item)
    }

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
        // An in-progress dirty edit is never silently replaced; surface the
        // discard confirmation instead and let the user decide.
        if isEditing, model?.isDirty == true {
            model?.requestClose()
            return
        }
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
        model.onEditRequest = { [weak self] in self?.requestEditFromPreview() }
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
            MainThreadIsolation.run {
                if event.window !== self.panel { self.close() }
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainThreadIsolation.run { self?.close() }
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
    /// Asks the host to swap this read-only preview for the editor ("e" key /
    /// the header's edit button). No-op when already editing.
    var onEditRequest: () -> Void = {}

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
        // No changes: closing is all the user wants; skipping the store write
        // also preserves the item's rich payload (saving would clear it).
        guard isDirty else {
            onDismiss()
            return
        }
        let item = item
        let newText = text
        Task { await ClipboardHistoryStore.shared.updateText(item, newText: newText) }
        onDismiss()
    }

    func requestEdit() {
        guard !isEditable else { return }
        onEditRequest()
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
        .focusEffectDisabled()
    }

    private var header: some View {
        HStack {
            LocalizedText(model.isEditable ? .clipboardEditTitle : .clipboardPreviewTitle)
                .font(.headline)
            Spacer()
            if !model.isEditable {
                // Doubles as the discoverability hint for the "e" shortcut.
                Button { model.requestEdit() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil")
                        LocalizedText(.clipboardActionEdit)
                        Text("E")
                            .font(.caption2.bold())
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L(.clipboardActionEdit))
                .padding(.trailing, 6)
            }
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
