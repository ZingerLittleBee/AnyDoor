import SwiftUI

/// Single row pinned above the menu-bar panel rows when a non-skipped update
/// is available. Calls `UpdateService` directly; nothing in this view knows
/// Sparkle exists.
struct UpdateBannerView: View {
    let version: String
    let onActivate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(Color.accentColor)
            Text(L(.updateBannerAvailable, version))
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button(action: onActivate) {
                Image(systemName: "chevron.right")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(L(.updateBannerViewAndInstall))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(L(.updateBannerDismissForSession))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.12))
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
    }
}

#Preview {
    UpdateBannerView(version: "1.2.0", onActivate: {}, onDismiss: {})
        .frame(width: 260)
        .padding()
}
