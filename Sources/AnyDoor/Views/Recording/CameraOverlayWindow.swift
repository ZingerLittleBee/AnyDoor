import AVFoundation
import AppKit

/// A small, draggable, always-on-top webcam preview shown during recording. The
/// screen recording captures it on screen (the simple, robust way to get a camera
/// overlay without compositing). Uses its own preview-only `AVCaptureSession`.
@MainActor
final class CameraOverlayWindow {
    static let shared = CameraOverlayWindow()
    private var panel: NSPanel?
    private var session: AVCaptureSession?

    private init() {}

    func show() {
        guard panel == nil else { return }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }

        let size = CGSize(width: 180, height: 135)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = CGPoint(x: screen.minX + 24, y: screen.minY + 24)
        let p = DraggablePanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = container.bounds
        preview.cornerRadius = 12
        container.layer?.addSublayer(preview)
        p.contentView = container

        session.startRunning()
        p.orderFrontRegardless()
        self.panel = p
        self.session = session
    }

    func hide() {
        session?.stopRunning()
        session = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// Borderless panel that can be dragged anywhere on its body.
private final class DraggablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
