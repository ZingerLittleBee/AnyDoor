import AppKit
import SwiftUI

struct QuicklinkIconView<Fallback: View>: View {
    let request: QuicklinkIconRequest?
    let size: CGFloat
    /// Drawn until the icon resolves, and in its place when there is none.
    @ViewBuilder let fallback: () -> Fallback

    @State private var resolvedRequest: QuicklinkIconRequest?
    @State private var resolvedIcon: NSImage?

    var body: some View {
        Group {
            if let icon = currentIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                fallback()
            }
        }
        .task(id: request) {
            guard let request else {
                resolvedRequest = nil
                resolvedIcon = nil
                return
            }
            resolvedRequest = request
            if let cached = QuicklinkIconProvider.cached(request) {
                resolvedIcon = cached
                return
            }
            resolvedIcon = nil
            let icon = await QuicklinkIconProvider.icon(for: request)
            guard !Task.isCancelled, resolvedRequest == request else { return }
            resolvedIcon = icon
        }
    }

    private var currentIcon: NSImage? {
        guard let request else { return nil }
        if let cached = QuicklinkIconProvider.cached(request) { return cached }
        guard resolvedRequest == request else { return nil }
        return resolvedIcon
    }
}

extension QuicklinkIconView where Fallback == QuicklinkSymbolIcon {
    init(request: QuicklinkIconRequest?, fallbackSymbol: String, size: CGFloat, symbolPointSize: CGFloat = 13) {
        self.init(request: request, size: size) {
            QuicklinkSymbolIcon(symbol: fallbackSymbol, size: size, pointSize: symbolPointSize)
        }
    }
}

/// The default fallback: the Quicklink's symbol, dimmed, in the icon's frame.
struct QuicklinkSymbolIcon: View {
    let symbol: String
    let size: CGFloat
    let pointSize: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: pointSize))
            .foregroundStyle(.secondary)
            .opticallyCentered(symbol: symbol, pointSize: pointSize)
            .frame(width: size, height: size)
    }
}
