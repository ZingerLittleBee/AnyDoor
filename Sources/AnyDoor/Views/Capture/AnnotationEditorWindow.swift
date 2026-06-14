import AppKit
import SwiftUI

/// Phase 0 placeholder. Opens a real (non-panel) titled window showing the
/// captured image with a "coming soon" banner. Phase 1 replaces the body with
/// the real annotation editor.
///
/// Registered with `RegularWindowCoordinator` so the Dock icon appears while
/// the window is open. Single-instance: a second call to `show(image:)` brings
/// the existing window to front rather than opening a new one.
@MainActor
final class AnnotationEditorWindow {
    static let shared = AnnotationEditorWindow()
    private var window: NSWindow?

    private init() {}

    func show(image: NSImage) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let size = CGSize(
            width: min(image.size.width, 900),
            height: min(image.size.height, 700) + 44
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
        w.contentView = NSHostingView(rootView: AnnotationEditorPlaceholderView(image: image))
        w.delegate = WindowCloseRelay.shared
        WindowCloseRelay.shared.onClose = { [weak self] in self?.window = nil }
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
    static let shared = WindowCloseRelay()
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private struct AnnotationEditorPlaceholderView: View {
    let image: NSImage

    var body: some View {
        VStack(spacing: 0) {
            Text(L(.captureEditorPlaceholder))
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.yellow.opacity(0.25))
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        }
    }
}
