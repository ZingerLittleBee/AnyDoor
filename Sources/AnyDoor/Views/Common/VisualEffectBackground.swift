import AppKit
import SwiftUI

/// System material background for custom layouts that cannot get it for free
/// from `.listStyle(.sidebar)` / `NavigationSplitView`.
///
/// Behind-window blending lets the desktop show through, matching the
/// Finder/Mail sidebar vibrancy; the system handles Dark Mode and the Reduce
/// Transparency accessibility setting automatically. SwiftUI's own
/// `.regularMaterial` is a within-window blur — with nothing behind it inside
/// the window it collapses to a flat gray, which is why it is not used here.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
    }
}
