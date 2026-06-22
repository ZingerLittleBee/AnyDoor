import SwiftUI

extension View {
    /// Lightweight hover tooltip rendered as in-panel content.
    ///
    /// SwiftUI's `.help(_:)` does not render a tooltip for views hosted in our
    /// hand-built panels (a bare `NSPanel` + `NSHostingView`, e.g. the translation
    /// panel) — `.onHover` still fires there, but no system tooltip appears (a
    /// system tooltip window can also end up behind a `.floating` panel). This
    /// draws its own bubble after a short hover delay; being part of the panel's
    /// own view tree, it always sits on top of the panel. `edge` is the side of
    /// the anchor the bubble appears on — use `.bottom` for controls near the
    /// panel's top (e.g. the toolbar) so the bubble doesn't fall off the top.
    func hoverTooltip(_ text: String, edge: VerticalEdge = .top) -> some View {
        modifier(HoverTooltipModifier(text: text, edge: edge))
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let text: String
    let edge: VerticalEdge
    @State private var hovering = false
    @State private var visible = false
    // Defaults high so the very first frame sits above (never on top of) the
    // anchor; corrected to the real height once measured.
    @State private var bubbleHeight: CGFloat = 30

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if inside {
                    // Delay so the bubble only appears on a deliberate rest, not a
                    // pass-through; re-check `hovering` in case the cursor left.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard hovering else { return }
                        withAnimation(.easeOut(duration: 0.12)) { visible = true }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { visible = false }
                }
            }
            .overlay(alignment: edge == .top ? .top : .bottom) {
                if visible {
                    // Anchored to the chosen edge, then pushed fully clear of the
                    // anchor by its own measured height plus a 6pt gap so it never
                    // covers it (custom alignment guides aren't honored by overlay).
                    bubble
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(key: TooltipHeightKey.self, value: proxy.size.height)
                            }
                        )
                        .onPreferenceChange(TooltipHeightKey.self) { bubbleHeight = $0 }
                        .offset(y: (edge == .top ? -1 : 1) * (bubbleHeight + 6))
                }
            }
    }

    private var bubble: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1))
            )
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

private struct TooltipHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
