import AppKit
import SwiftUI

/// Hosts the annotation editor (Phase 1). Opens a real (non-panel) titled window
/// presenting `AnnotationEditorView` over the captured image — arrows, shapes,
/// text, blur/pixelate, crop, and the rest of the tool set.
///
/// Registered with `RegularWindowCoordinator` so the Dock icon appears while
/// the window is open. Single-instance: a second call to `show(image:)` brings
/// the existing window to front rather than opening a new one.
@MainActor
final class AnnotationEditorWindow {
    static let shared = AnnotationEditorWindow()
    private var window: NSWindow?
    private var closeRelay: WindowCloseRelay?

    private init() {}

    func show(image: NSImage) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // Size the window to the screenshot's aspect ratio so it opens matching the
        // capture's shape, clamped to a comfortable editor range. `image.size` can be
        // zero for cg-backed NSImages, so derive everything from the pixel dimensions.
        let aspect: CGFloat = (cg.width > 0 && cg.height > 0)
            ? CGFloat(cg.width) / CGFloat(cg.height)
            : 1.6
        let chromeHeight: CGFloat = 96  // top toolbar + style bar + dividers
        var canvasWidth = min(1200, max(760, CGFloat(1000)))
        var canvasHeight = canvasWidth / aspect
        if canvasHeight > 760 {
            canvasHeight = 760
            canvasWidth = min(1200, max(760, canvasHeight * aspect))
        } else if canvasHeight < 460 {
            canvasHeight = 460
        }
        let size = CGSize(width: canvasWidth, height: canvasHeight + chromeHeight)
        let w = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = L(.builtinScreenshot)
        w.isRestorable = false
        // We retain the window in `self.window` and release it on close, so AppKit
        // must not also auto-release it — otherwise the window is over-released and
        // crashes in objc_release during the autorelease-pool pop. Matches every
        // other window/panel controller in the app.
        w.isReleasedWhenClosed = false
        w.center()
        let model = AnnotationEditorModel(image: cg)
        w.contentView = NSHostingView(rootView: AnnotationEditorView(model: model) { [weak self] in
            self?.window?.close()
        })
        let relay = WindowCloseRelay()
        relay.onClose = { [weak self] in
            self?.window = nil
            self?.closeRelay = nil
        }
        w.delegate = relay
        closeRelay = relay
        window = w
        RegularWindowCoordinator.shared.track(w)
        // The capture overlay is a non-activating panel, so AnyDoor isn't frontmost
        // when "edit" is tapped. Activate (now that the policy is `.regular`) and
        // front the window, mirroring HostsEditorWindowController / SettingsOpener —
        // otherwise the editor opens behind the app that was captured.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// Minimal `NSWindowDelegate` that fires a closure when the window closes,
/// allowing `AnnotationEditorWindow` to nil its strong reference and accept a
/// future `show(image:)` call.
@MainActor
private final class WindowCloseRelay: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
