import SwiftUI

extension View {
    /// Lightweight hover tooltip rendered as in-panel content.
    ///
    /// SwiftUI's `.help(_:)` does not render a tooltip for views hosted in our
    /// hand-built panels (a bare `NSPanel` + `NSHostingView`, e.g. the translation
    /// panel) — `.onHover` still fires there, but no system tooltip appears (a
    /// system tooltip window can also end up behind a `.floating` panel). This
    /// draws its own bubble above the view after a short hover delay; being part
    /// of the panel's own view tree, it always sits on top of the panel.
    func hoverTooltip(_ text: String) -> some View {
        modifier(HoverTooltipModifier(text: text))
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let text: String
    @State private var hovering = false
    @State private var visible = false

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
            .overlay(alignment: .top) {
                if visible {
                    // Height-independent placement: pin the bubble's bottom edge
                    // 6pt above the anchor's top.
                    bubble.alignmentGuide(.top) { $0[.bottom] + 6 }
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
