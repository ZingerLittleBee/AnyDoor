import PluginInterface
import SwiftUI

/// Shown in the Hosts popover and editor when the privileged helper is
/// registered but still awaiting the user's approval in System Settings.
/// Renders nothing when the helper is enabled or unavailable (dev/ad-hoc
/// builds fall back to the AppleScript writer and need no nagging).
struct HelperApprovalBanner: View {
    @Environment(\.pluginHostContext) private var host

    var body: some View {
        if host?.helperReadiness() == .requiresApproval {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                LocalizedText(.hostsHelperApproval)
                    .font(.caption2)
                Spacer()
                Button(L(host, .hostsActionAuthorize)) { host?.helper.openApprovalSettings() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
    }
}
