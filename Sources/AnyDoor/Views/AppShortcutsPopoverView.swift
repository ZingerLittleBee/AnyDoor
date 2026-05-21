import SwiftUI
import AppKit

/// SwiftUI content shown inside the HoverPopover for the App Shortcuts submenu.
///
/// Lists each KeyBinding with its hotkey and app name. Read-only mapping view —
/// editing happens in the Settings window.
struct AppShortcutsPopoverView: View {
    let entries: [PanelEntry]
    var onHoverChange: (Bool) -> Void
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
                Text("应用快捷键").font(.headline)
                Text("· \(visibleEntries.count) 个").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            if !visibleEntries.isEmpty {
                Divider().padding(.horizontal, 8)

                // GlassEffectContainer keeps per-row interactive glass effects in sync
                // (same reason as the menu bar list — without it, edge rows tint inconsistently).
                GlassEffectContainer(spacing: 2) {
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
            }
        }
        .frame(minWidth: 240, maxWidth: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHover(perform: onHoverChange)
    }
}

private struct AppShortcutRow: View {
    let entry: PanelEntry
    let appPath: String?
    var onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            appIcon
            Text(entry.title)
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let hotkey = entry.hotkey {
                Text(hotkey.displayString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help("切换 \(entry.title)")
        .onHover { hovering in
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
