import SwiftUI

/// Wraps Liquid Glass APIs so the app can keep a lower deployment target.
struct AdaptiveGlassEffectContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    /// Standalone interactive surface that paints its OWN material / glass. Use
    /// it only for an interactive element sitting directly on the desktop or on a
    /// non-material backdrop. Do NOT use it for rows inside a panel that already
    /// has a material background (the menu-bar panel, the hover popovers) —
    /// stacking a second material per row brightens and flattens the rows in
    /// light mode. For those, keep idle rows transparent and paint a hover tint
    /// (`Color.primary.opacity(0.06)`), or use `adaptiveMenuBarRowSurface`.
    @ViewBuilder
    func adaptiveInteractiveSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

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

/// Applies a fallback `.thickMaterial` background on systems before macOS 26.
/// On macOS 26+ the panel relies on its outer Liquid Glass surface to render
/// rows/headers, so per-element materials are dropped to avoid double-layer
/// composites that show up as visible seams against the glass.
struct LegacyMaterialBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.background(.thickMaterial)
        }
    }
}

extension View {
    func legacyMaterialBackground() -> some View {
        modifier(LegacyMaterialBackground())
    }
}

/// Adaptive surface for full-width pinned section headers. macOS 26+ uses a
/// thin material so the band stays subtle on top of the panel's Liquid Glass
/// — heavy materials or a nested `.glassEffect()` would render as a dark
/// opaque strip that breaks the design language. Earlier systems fall back
/// to `.thickMaterial` to match the surrounding non-glass surface.
struct AdaptiveStickyHeaderSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.background(.thinMaterial)
        } else {
            content.background(.thickMaterial)
        }
    }
}

extension View {
    func adaptiveStickyHeaderSurface() -> some View {
        modifier(AdaptiveStickyHeaderSurface())
    }
}
