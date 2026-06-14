import AppKit
import SwiftUI

/// An always-on-top floating image for reference. Drag to move, adjust opacity,
/// toggle click-through, close. Each pin is its own window so several can coexist.
@MainActor
final class PinnedImageWindow {
    private static var windows: [PinnedImageWindow] = []

    private var panel: NSPanel?
    private var clickThrough = false

    static func show(image: NSImage, at screenFrame: CGRect) {
        let win = PinnedImageWindow()
        win.present(image: image, at: screenFrame)
        windows.append(win)
    }

    private func present(image: NSImage, at screenFrame: CGRect) {
        let maxDimension: CGFloat = 360
        let aspect = image.size.height / max(image.size.width, 1)
        let width = min(image.size.width, maxDimension)
        let size = CGSize(width: width, height: width * aspect)
        let origin = CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )

        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: PinnedImageView(
            image: image,
            onClose: { [weak self] in self?.close() },
            onOpacity: { [weak self] value in self?.panel?.alphaValue = value },
            onToggleClickThrough: { [weak self] in self?.toggleClickThrough() }
        ))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        panel = p
        p.orderFrontRegardless()
    }

    private func toggleClickThrough() {
        clickThrough.toggle()
        panel?.ignoresMouseEvents = clickThrough
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        PinnedImageWindow.windows.removeAll { $0 === self }
    }
}

private struct PinnedImageView: View {
    let image: NSImage
    let onClose: () -> Void
    let onOpacity: (CGFloat) -> Void
    let onToggleClickThrough: () -> Void

    @State private var opacity: Double = 1
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
            if hovering {
                HStack(spacing: 8) {
                    Slider(value: $opacity, in: 0.2...1).frame(width: 80)
                        .onChange(of: opacity) { _, v in onOpacity(CGFloat(v)) }
                    Button(action: onToggleClickThrough) {
                        Image(systemName: "cursorarrow.slash")
                    }
                    .buttonStyle(.plain)
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
    }
}
