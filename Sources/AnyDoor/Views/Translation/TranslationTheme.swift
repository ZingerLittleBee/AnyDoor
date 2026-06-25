import SwiftUI

/// Design tokens and adaptive surface helpers for the translation window. Centralizes
/// the spacing, radius, and tint values every translation sub-view used to hardcode,
/// and expresses the "unified glass shell" surface model on top of
/// `LiquidGlassCompatibility`: one glass hero surface, a recessed input well, and
/// flat content tiles for results (no material-on-material stacking on any OS).
enum TranslationTheme {
    // Spacing
    static let windowPadding: CGFloat = 16
    static let sectionGap: CGFloat = 12
    static let tileInsetH: CGFloat = 14
    static let tileInsetV: CGFloat = 10
    static let controlGap: CGFloat = 8

    // Radius
    static let shellRadius: CGFloat = 16
    static let tileRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8

    // Tints — plain primary-opacity fills, so they composite cleanly on both the
    // glass shell (macOS 26) and the material shell (fallback) without stacking.
    static let wellFill = Color.primary.opacity(0.04)
    static let hairline = Color.primary.opacity(0.08)

    /// Result/history tile background tint: clear at rest, a faint wash on hover,
    /// slightly stronger while expanded.
    static func tileTint(isHovered: Bool, isExpanded: Bool) -> Color {
        if isExpanded { return Color.primary.opacity(0.07) }
        if isHovered { return Color.primary.opacity(0.05) }
        return .clear
    }

    /// Small-control fill used on the fallback (pre-macOS-26) path for chips and
    /// toolbar buttons; brightens on hover.
    static func controlTint(isHovered: Bool) -> Color {
        Color.primary.opacity(isHovered ? 0.12 : 0.06)
    }

    /// Soft fill for informational meta chips (e.g. the detected-language hint).
    /// Kept on the secondary color so it reads as a passive badge, not a control.
    static let metaChipFill = Color.secondary.opacity(0.12)
}

extension View {
    /// The window's hero surface. macOS 26 paints one Liquid Glass sheet; earlier
    /// systems fall back to today's `.regularMaterial`.
    @ViewBuilder
    func translationShell() -> some View {
        let shape = RoundedRectangle(cornerRadius: TranslationTheme.shellRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// Recessed input "well": a faint fill plus a hairline stroke, no material/glass,
    /// so it reads as inset on both the glass and the fallback shell.
    func translationWell() -> some View {
        let shape = RoundedRectangle(cornerRadius: TranslationTheme.tileRadius, style: .continuous)
        return self
            .background(TranslationTheme.wellFill, in: shape)
            .overlay(shape.stroke(TranslationTheme.hairline, lineWidth: 1))
    }

    /// A result/history content tile. No own material — a faint tint marks hover and
    /// the expanded state. This is what removes the old material-on-material stacking.
    func translationTile(isHovered: Bool, isExpanded: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: TranslationTheme.tileRadius, style: .continuous)
        return self
            .background(TranslationTheme.tileTint(isHovered: isHovered, isExpanded: isExpanded), in: shape)
            .clipShape(shape)
    }

    /// Small interactive control surface for toolbar buttons, language chips, and the
    /// swap button. macOS 26: interactive Liquid Glass, tinted with the accent when
    /// active. Earlier systems: a soft opacity fill (accent fill when active). With
    /// `idleVisible == false` the surface only appears on hover/active, so idle
    /// toolbar glyphs stay flat like the system toolbar treatment.
    @ViewBuilder
    func translationControlSurface(
        shape: some Shape,
        isHovered: Bool,
        isActive: Bool = false,
        idleVisible: Bool = true
    ) -> some View {
        if #available(macOS 26.0, *) {
            if isActive {
                self.glassEffect(.regular.tint(.accentColor).interactive(), in: shape)
            } else if idleVisible || isHovered {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self
            }
        } else {
            if isActive {
                self.background(Color.accentColor, in: shape)
            } else if idleVisible || isHovered {
                self.background(TranslationTheme.controlTint(isHovered: isHovered), in: shape)
            } else {
                self
            }
        }
    }
}
