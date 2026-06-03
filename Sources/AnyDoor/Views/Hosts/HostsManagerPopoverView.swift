import SwiftUI

/// Hover popover for the Hosts submenu. Matches the shared popover styling
/// (material card + glass rows): a header carrying the title and the
/// create/edit actions, a read-only System Hosts entry with an "open file"
/// action, and quick activation toggles for each profile.
struct HostsManagerPopoverView: View {
    @Bindable var manager: HostsManager
    let onHoverChange: (Bool) -> Void
    let onEdit: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HelperApprovalBanner()
            if let error = manager.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }

            AdaptiveGlassEffectContainer(spacing: 2) {
                VStack(spacing: 2) {
                    systemHostsRow
                    ForEach(manager.profiles) { profile in
                        profileRow(profile)
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .frame(width: 260)
        // fixedSize forces the full intrinsic height so the hover panel measures
        // and shows every row instead of clipping the bottom rows.
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHover { onHoverChange($0) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle").foregroundStyle(.secondary)
            Text("Hosts 管理").font(.headline)
            Spacer()
            Button { onEdit() } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.plain)
            .help("打开 Hosts 管理窗口")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: - Rows

    private var systemHostsRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu").foregroundStyle(.secondary)
            Text("系统 Hosts")
            Spacer()
            Button { HostsFileOpener.open() } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .help("用默认编辑器打开")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .adaptiveInteractiveSurface(cornerRadius: 6)
    }

    private func profileRow(_ profile: HostProfile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: profile.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(profile.isActive ? .green : .secondary)
            Text(profile.name)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
        .adaptiveInteractiveSurface(cornerRadius: 6)
        .onTapGesture {
            Task { await manager.setActive(profile, !profile.isActive) }
        }
    }
}
