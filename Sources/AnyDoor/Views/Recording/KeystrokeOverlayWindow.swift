import AppKit
import PluginInterface
import PluginSupport

/// A bottom-center floating pill that shows the most recent keystroke combo during
/// recording. The screen recording captures it on screen. Observes key events via
/// global + local monitors (the app already holds Accessibility permission).
@MainActor
final class KeystrokeOverlayWindow {
    static let shared = KeystrokeOverlayWindow()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hideTask: Task<Void, Never>?

    private init() {}

    func show() {
        guard panel == nil else { return }
        let size = CGSize(width: 220, height: 56)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = CGPoint(x: screen.midX - size.width / 2, y: screen.minY + 80)
        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        container.layer?.cornerRadius = 12

        let label = NSTextField(labelWithString: "")
        label.font = .monospacedSystemFont(ofSize: 26, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = container.bounds.insetBy(dx: 10, dy: 12)
        label.autoresizingMask = [.width, .height]
        container.addSubview(label)
        p.contentView = container
        p.alphaValue = 0
        p.orderFrontRegardless()
        self.panel = p
        self.label = label

        let handler: (NSEvent) -> Void = { [weak self] event in
            MainThreadIsolation.run { self?.present(event) }
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: handler)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainThreadIsolation.run { self?.present(event) }
            return event
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        label = nil
    }

    private func present(_ event: NSEvent) {
        let flags = event.modifierFlags
        let text = KeystrokeFormatter.display(
            keyCode: Int(event.keyCode),
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift),
            command: flags.contains(.command)
        )
        label?.stringValue = text
        panel?.animator().alphaValue = 1
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.panel?.animator().alphaValue = 0
        }
    }
}
