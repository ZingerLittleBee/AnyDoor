import AppKit
import SwiftUI

/// A borderless panel that can still become key, so the hosted text fields accept
/// input while it acts as a full-window modal scrim.
private final class EditorScrimPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Presents the translation service editor as a modal dialog centered over — and
/// dimming — the *entire* Settings window, including the tab bar. The tab bar
/// lives in the window's title/toolbar area (the SwiftUI `Settings` scene renders
/// it there), which a SwiftUI overlay inside a tab cannot cover; so the scrim is
/// a borderless child window pinned to the parent window's frame. The card is
/// centered within that full-window scrim.
@MainActor
final class TranslationServiceEditorOverlay {
    static let shared = TranslationServiceEditorOverlay()

    private var scrim: EditorScrimPanel?
    /// Observes the parent Settings window closing while the editor is up, so a
    /// child scrim is never orphaned (AppKit detaches a child on parent close but
    /// never calls our `dismiss()`).
    private var parentCloseObserver: NSObjectProtocol?

    private init() {}

    func present(
        config: TranslationServiceConfig,
        isNew: Bool,
        keychain: TranslationKeychainStore,
        onSave: @escaping (TranslationServiceConfig, String?) -> Void
    ) {
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        dismiss()

        let panel = EditorScrimPanel(
            contentRect: parent.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // A transient utility scrim; never restore it on launch.
        panel.isRestorable = false
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        // NSPanel defaults `becomesKeyOnlyIfNeeded` to true, which leaves the
        // borderless scrim non-key so the hosted text fields never accept typing
        // and the Esc/Return shortcuts never route. Every key-accepting panel in
        // this app (CommandPaletteWindowController, SpotlightAppPicker…) clears it.
        panel.becomesKeyOnlyIfNeeded = false

        let root = TranslationServiceEditorScrim(
            config: config,
            isNew: isNew,
            keychain: keychain,
            onSave: { [weak self] saved, apiKey in
                onSave(saved, apiKey)
                self?.dismiss()
            },
            onCancel: { [weak self] in self?.dismiss() }
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: parent.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        // Pin to the parent's frame and keep it attached so it covers the whole
        // window (title/toolbar included) and follows the parent.
        parent.addChildWindow(panel, ordered: .above)
        panel.setFrame(parent.frame, display: true)
        // Activate the app BEFORE keying the panel. This `.accessory` app may be
        // backgrounded, and a borderless child panel cannot reliably become key
        // (so SwiftUI @FocusState can't hold first responder and typing fails)
        // until the app is frontmost — same fix CommandPaletteWindowController uses.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        scrim = panel

        // Tear down if the Settings window closes while the editor is open.
        parentCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: parent,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    func dismiss() {
        if let parentCloseObserver {
            NotificationCenter.default.removeObserver(parentCloseObserver)
            self.parentCloseObserver = nil
        }
        guard let scrim else { return }
        scrim.parent?.removeChildWindow(scrim)
        scrim.orderOut(nil)
        self.scrim = nil
    }
}

/// The dimmed backdrop plus the centered editor card, hosted inside the scrim
/// window so the dim covers the whole Settings window.
private struct TranslationServiceEditorScrim: View {
    let config: TranslationServiceConfig
    let isNew: Bool
    let keychain: TranslationKeychainStore
    let onSave: (TranslationServiceConfig, String?) -> Void
    let onCancel: () -> Void

    var body: some View {
        // The scrim fills the parent window's frame, so the proxy height equals
        // the window height; the card takes 90% of it and stays centered.
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()

                TranslationServiceConfigSheet(
                    config: config,
                    isNew: isNew,
                    keychain: keychain,
                    onSave: onSave,
                    onCancel: onCancel
                )
                .frame(width: 512, height: proxy.size.height * 0.9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
