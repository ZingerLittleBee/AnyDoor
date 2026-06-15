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
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let size = CGSize(
            width: min(max(image.size.width, 640), 1100),
            height: min(max(image.size.height, 460), 800) + 92
        )
        let w = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = L(.builtinScreenshot)
        w.isRestorable = false
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
