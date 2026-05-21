import SwiftUI

/// Renders a single PanelEntry in the menu bar panel.
///
/// Three visual variants driven by `entry.kind`:
/// - `.toggle`  — icon + title + (subtitle) + right-side switch
/// - `.action`  — icon + title + optional right-side hotkey label (HIG menu-item style)
/// - `.submenu` — icon + title + (subtitle) + right-side chevron
///
/// All rows are tappable on the whole row, matching Apple-menu / NSMenuItem behavior.
struct PanelRowView: View {
    let entry: PanelEntry
    var onToggle: () -> Void
    var onAction: () -> Void
    var onSubmenu: () -> Void
    var onPermission: () -> Void

    @State private var activationPulse = 0

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
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if needsPermission { onPermission(); return }
            triggerFeedback()
            switch entry.kind {
            case .toggle:  onToggle()
            case .submenu: onSubmenu()
            case .action:  onAction()
            }
        }
    }

    /// Visual + auditory feedback fired the instant the user activates an entry.
    ///
    /// Animation runs for every kind (so users get the same affordance everywhere);
    /// sound only fires for items that opt in via `BuiltinItem.feedbackSound`.
    private func triggerFeedback() {
        activationPulse &+= 1
        if case let .builtin(item) = entry.source {
            item.feedbackSound?.play()
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
                .symbolEffect(.bounce, value: activationPulse)
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
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        case .submenu:
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
