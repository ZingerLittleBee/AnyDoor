import SwiftUI

/// Non-blocking guidance shared by the menu panel and Hyper Key settings.
struct SecureInputWarningView: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(.secureInputWarningTitle)
                    .fontWeight(.medium)
                LocalizedText(.secureInputWarningHelp)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
