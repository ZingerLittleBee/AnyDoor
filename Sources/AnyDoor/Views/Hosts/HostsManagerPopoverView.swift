import SwiftUI

/// Hover popover for the Hosts submenu: quick activation toggles, a read-only
/// System Hosts entry with an "open file" action, and buttons to create/edit.
struct HostsManagerPopoverView: View {
    @Bindable var manager: HostsManager
    let onHoverChange: (Bool) -> Void
    let onEdit: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HelperApprovalBanner()
            if let error = manager.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
            // System Hosts (read-only)
            HStack {
                Image(systemName: "cpu")
                Text("系统 Hosts")
                Spacer()
                Button {
                    HostsFileOpener.open()
                } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            Divider()

            ForEach(manager.profiles) { profile in
                HStack {
                    Image(systemName: profile.isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(profile.isActive ? .green : .secondary)
                    Text(profile.name)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 8).padding(.vertical, 6)
                .onTapGesture {
                    Task { await manager.setActive(profile, !profile.isActive) }
                }
            }

            Divider()
            HStack {
                Button { manager.createProfile(name: newProfileName()) } label: {
                    Label("新建", systemImage: "plus")
                }
                Spacer()
                Button { onEdit() } label: {
                    Label("编辑", systemImage: "pencil")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: 240)
        // fixedSize forces the full intrinsic height so the hover panel measures
        // and shows every row instead of clipping the bottom buttons.
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHover { onHoverChange($0) }
    }

    private func newProfileName() -> String {
        let base = "新配置"
        let existing = Set(manager.profiles.map(\.name))
        if !existing.contains(base) { return base }
        var i = 2
        while existing.contains("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}
