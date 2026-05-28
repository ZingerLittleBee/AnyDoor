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
    @ViewBuilder
    func adaptiveInteractiveSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
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
