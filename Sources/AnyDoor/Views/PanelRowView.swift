import SwiftUI

/// Renders a single PanelEntry in the menu bar panel.
///
/// Three visual variants driven by `entry.kind`:
/// - `.toggle`  — icon + title + (subtitle) + right-side switch
/// - `.action`  — icon + title + optional hotkey + chevron when the action has a hover popover
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

    /// True when the row is a built-in action that exposes a hover-only history popover
    /// (OCR / pick color / QR / screenshot). Used to render an affordance chevron so
    /// users discover hover-to-reveal even when no hotkey is bound.
    private var hasHoverPopover: Bool {
        if case let .builtin(item) = entry.source { return item.historyKind != nil }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            iconBadge
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.localizedTitle()).font(.body)
                if needsPermission {
                    LocalizedText(.panelRowNeedsPermission)
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
        .adaptiveInteractiveSurface(cornerRadius: 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if needsPermission { onPermission(); return }
            triggerFeedback()
            switch entry.kind {
            case .toggle:  onToggle()
            case .submenu: onSubmenu()
            case .action:  onAction()
            case .brightnessControl: break          // click is intentionally a no-op (hover-only UI)
            case .hiddenHotkey: break                // never reaches PanelRowView; defensive only
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
            .controlSize(.small)
            .tint(.accentColor)
            .environment(\.appearsActive, true)
            .labelsHidden()
            .disabled(needsPermission)
            .opacity(0.01)
            .overlay {
                PanelSwitchIndicator(
                    isOn: entry.toggleState ?? false,
                    isEnabled: !needsPermission
                )
                .allowsHitTesting(false)
            }
            .frame(width: 42, height: 24)
        case .action:
            HStack(spacing: 6) {
                if let hk = entry.hotkey {
                    HotkeyLabel(hotkey: hk)
                }
                if hasHoverPopover {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        case .submenu:
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .brightnessControl:
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
        case .hiddenHotkey:
            EmptyView()
        }
    }
}

private struct PanelSwitchIndicator: View {
    let isOn: Bool
    let isEnabled: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(trackColor)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                .padding(2)
        }
        .frame(width: 42, height: 24)
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.snappy(duration: 0.16), value: isOn)
    }

    private var trackColor: Color {
        if isOn { return .accentColor }
        return .secondary.opacity(0.28)
    }
}
