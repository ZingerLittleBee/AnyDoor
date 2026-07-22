import PluginInterface
import PluginSupport
import SwiftUI
import AppKit

/// SwiftUI content shown inside the HoverPopover for the App Shortcuts submenu.
///
/// Lists each KeyBinding with its hotkey and app name. Read-only mapping view —
/// editing happens in the Settings window.
struct AppShortcutsPopoverView: View {
    let entries: [PanelEntry]
    var onHoverChange: @MainActor (Bool) -> Void
    var onSelect: (PanelEntry) -> Void
    /// Resolves the on-disk app path for an entry so the row can render a Finder app icon.
    /// Returns nil when the entry isn't an app shortcut or its KeyBinding is missing.
    var appPath: (PanelEntry) -> String?

    private var visibleEntries: [PanelEntry] {
        entries.filter(\.isVisible)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                LocalizedText(.builtinAppShortcuts).font(.headline)
                Text(L(.panelAppShortcutCountSuffix, visibleEntries.count)).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            if !visibleEntries.isEmpty {
                Divider().padding(.horizontal, 8)

                AdaptiveGlassEffectContainer(spacing: 2) {
                    VStack(spacing: 2) {
                        ForEach(visibleEntries) { entry in
                            AppShortcutRow(
                                entry: entry,
                                appPath: appPath(entry),
                                onSelect: { onSelect(entry) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
            } else {
                // First-run guidance: with nothing configured, point the user at
                // the Settings window where shortcuts are added and bound.
                HStack(spacing: 6) {
                    Image(systemName: "plus.app").foregroundStyle(.tertiary)
                    LocalizedText(.panelAppShortcutEmpty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .frame(minWidth: 240, maxWidth: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHoverSafe(perform: onHoverChange)
    }
}

private struct AppShortcutRow: View {
    let entry: PanelEntry
    let appPath: String?
    var onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            appIcon
            Text(entry.localizedTitle())
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let hotkey = entry.hotkey {
                HotkeyLabel(hotkey: hotkey)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contentShape(Rectangle())
        // Idle rows stay transparent so the popover's single .regularMaterial
        // shows through; only hover paints a neutral tint — matching the
        // PortListView / PortTreeView rows. (Previously each row stacked an
        // interactive glass surface that rendered brighter than the popover
        // background in light mode.)
        .background(
            isHovered ? Color.primary.opacity(0.06) : .clear,
            in: .rect(cornerRadius: 6)
        )
        .onTapGesture(perform: onSelect)
        .help(L(.panelAppShortcutToggleHelp, entry.localizedTitle()))
        .onHoverSafe { hovering in
            isHovered = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let path = appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "app.fill")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        }
    }
}
