import AppKit
import SwiftUI

struct QuicklinkIconView: View {
    let request: QuicklinkIconRequest?
    let fallbackSymbol: String
    let size: CGFloat
    var symbolPointSize: CGFloat = 13

    @State private var resolvedRequest: QuicklinkIconRequest?
    @State private var resolvedIcon: NSImage?

    var body: some View {
        Group {
            if let icon = currentIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: symbolPointSize))
                    .foregroundStyle(.secondary)
                    .opticallyCentered(symbol: fallbackSymbol, pointSize: symbolPointSize)
            }
        }
        .frame(width: size, height: size)
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
