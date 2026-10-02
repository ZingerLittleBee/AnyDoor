import SwiftUI

// `AdaptiveGlassEffectContainer` lives in PluginSupport so plugin modules
// can share the panel/popover styling; the surface helpers below stay Core.

extension View {
    /// Interactive surface for rows that already live inside a single material
    /// panel (the menu-bar panel — see `MenuBarController`, whose container is
    /// already wrapped in `.regularMaterial`). On macOS 26+ each row gets its
    /// own interactive Liquid Glass capsule, which composites cleanly over the
    /// panel glass. On earlier systems the row stays transparent instead of
    /// stacking a second `.regularMaterial` on top of the panel's material —
    /// two stacked materials brighten and desaturate in light mode, flattening
    /// the rows into one bright sheet — so idle rows let the panel material show
    /// through and rely on the caller's hover tint for separation.
    @ViewBuilder
    func adaptiveMenuBarRowSurface(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
        }
    }

    /// Non-interactive panel surface. Use for large container backgrounds
    /// (palettes, popovers) where the surface itself isn't tappable.
    @ViewBuilder
    func adaptivePanelSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.thickMaterial, in: shape)
        }
    }
}
