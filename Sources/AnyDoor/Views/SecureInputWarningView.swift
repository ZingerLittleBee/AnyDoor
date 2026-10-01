import SwiftUI

/// Non-blocking guidance shared by the menu panel and Hyper Key settings.
struct SecureInputWarningView: View {
    let holder: SecureInputHolder

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(.secureInputWarningTitle)
                    .fontWeight(.medium)
                switch holder {
                case .application(let name):
                    Text(L(.secureInputWarningOwner, name))
                case .exitedProcess:
                    LocalizedText(.secureInputWarningOwnerExited)
                case .unknown:
                    LocalizedText(.secureInputWarningOwnerUnknown)
                }
                LocalizedText(helpKey)
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

    private var helpKey: L10n.Key {
        switch holder {
        case .application: .secureInputWarningHelpApplication
        case .exitedProcess: .secureInputWarningHelpExited
        case .unknown: .secureInputWarningHelpUnknown
        }
    }
}
