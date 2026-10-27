import AppKit
import SwiftUI

/// An app in a Settings list, identified by bundle ID, with one trailing
/// button that takes it off the list. A nil `path` (the app is not installed
/// here) shows a generic app symbol.
struct AppListRow: View {
    let displayName: String
    let bundleID: String
    let path: String?
    /// Tooltip and accessibility label of the remove button.
    let removeLabel: String
    let onRemove: () -> Void

    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Image(systemName: "app")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .lineLimit(1)
                Text(bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(removeLabel)
            .accessibilityLabel(removeLabel)
        }
        .padding(.vertical, 5)
        .task(id: path) {
            icon = nil
            guard let path else { return }
            if let cached = AppIconCache.cached(path) {
                icon = cached
            } else {
                icon = await AppIconCache.icon(for: path)
            }
        }
    }
}
