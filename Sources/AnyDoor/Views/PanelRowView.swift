import SwiftUI

/// Renders a single PanelEntry in the menu bar panel.
///
/// Three visual variants driven by `entry.kind`:
/// - `.toggle`  — icon + title + (subtitle) + right-side switch; entire row toggles
/// - `.action`  — icon + title + right-side hotkey label; entire row triggers
/// - `.submenu` — icon + title + (subtitle) + right-side chevron; entire row opens popover
struct PanelRowView: View {
    let entry: PanelEntry
    var onToggle: () -> Void
    var onAction: () -> Void
    var onSubmenu: () -> Void
    var onPermission: () -> Void

    @State private var isHovered = false

    private var needsPermission: Bool { entry.permission == .denied }

    var body: some View {
        HStack(spacing: 10) {
            iconBadge
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.body)
                if needsPermission {
                    Text("⚠ 需要权限")
                        .font(.caption2)
                        .foregroundStyle(Color.orange)
                } else if let subtitle = entry.subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                } else if let hotkey = entry.hotkey {
                    Text(hotkey.displayString)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture {
            if needsPermission { onPermission(); return }
            switch entry.kind {
            case .toggle:  onToggle()
            case .action:  onAction()
            case .submenu: onSubmenu()
            }
        }
    }

    @ViewBuilder private var iconBadge: some View {
        let tint: Color = (entry.toggleState == true)
            ? .accentColor.opacity(0.5)
            : (needsPermission ? .orange.opacity(0.4) : .secondary.opacity(0.25))
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.2))
            Image(systemName: entry.symbol)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
        }
        .frame(width: 24, height: 24)
    }

    @ViewBuilder private var trailing: some View {
        switch entry.kind {
        case .toggle:
            Toggle("", isOn: Binding(
                get: { entry.toggleState ?? false },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(needsPermission)
        case .action:
            if let hk = entry.hotkey {
                Text(hk.displayString)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                Text("—").foregroundStyle(.tertiary).font(.caption2)
            }
        case .submenu:
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
