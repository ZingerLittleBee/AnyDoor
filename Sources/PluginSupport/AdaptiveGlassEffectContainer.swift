import SwiftUI

/// Wraps the Liquid Glass container API so the app (and plugin modules) can
/// keep a lower deployment target: macOS 26+ composites the content as one
/// glass group, earlier systems render it unchanged.
public struct AdaptiveGlassEffectContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}
