import AppKit
import SwiftUI

/// Floating preview + Done/Cancel for an interactive scrolling capture. The
/// preview grows and auto-scrolls to the bottom as frames are stitched. The panel
/// is non-activating so the target window keeps scroll focus; the session grabs
/// the viewport *below* this panel so it never appears in the stitched image.
@MainActor
final class ScrollCaptureSessionWindow {
    private var panel: NSPanel?
    private let model = ScrollCaptureSessionModel()

    /// 0 until presented; the window number the session passes to the below-window grab.
    var windowNumber: Int { panel?.windowNumber ?? 0 }

    func present(viewport: CGRect, onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
        model.image = nil
        model.heightPx = 0
        model.onDone = onDone
        model.onCancel = onCancel
        guard panel == nil else { return }

        let size = CGSize(width: 320, height: 440)
        // Bottom-right of the viewport's display (does not matter for correctness —
        // the grab excludes this window — but keep it off the viewport visually).
        let screen = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: viewport.midX, y: viewport.midY)) }
                      ?? NSScreen.main)?.visibleFrame ?? .zero
        let origin = CGPoint(x: screen.maxX - size.width - 16, y: screen.minY + 16)
        let p = NSPanel(contentRect: CGRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: ScrollCaptureSessionView(model: model))
        p.orderFrontRegardless()
        panel = p
    }

    func updatePreview(_ image: NSImage, heightPx: Int) {
        model.image = image
        model.heightPx = heightPx
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
@Observable
final class ScrollCaptureSessionModel {
    var image: NSImage?
    var heightPx: Int = 0
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
}

private struct ScrollCaptureSessionView: View {
    @Bindable var model: ScrollCaptureSessionModel

    var body: some View {
        VStack(spacing: 10) {
            Text(L(.captureScrollTitle))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if let image = model.image {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                    .id("bottom")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: model.heightPx) { _, _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            Text(L(.captureScrollCaptured, model.heightPx))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(L(.captureScrollCancel)) { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L(.captureScrollDone)) { model.onDone?() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 320, height: 440)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
