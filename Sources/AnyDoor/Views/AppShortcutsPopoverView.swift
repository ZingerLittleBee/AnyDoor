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

                VStack(spacing: 2) {
                    ForEach(visibleEntries) { entry in
                        AppShortcutRow(entry: entry, onSelect: { onSelect(entry) })
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
    var onSelect: () -> Void

    @State private var hovered = false

    private var isRunning: Bool {
        guard case let .appShortcut(_) = entry.source else { return false }
        // Cheap lookup by scanning running apps for any whose path equals entry.subtitle?
        // Subtitle isn't reliable; use NSRunningApplication by symbol name approximation.
        // For accuracy we'd need bundleID — see Task 24 where PanelStore can inject runningSet.
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.hotkey?.displayString ?? "—")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            Text(entry.title).font(.body).lineLimit(1)
            Spacer(minLength: 0)
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(hovered ? Color.accentColor.opacity(0.1) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
