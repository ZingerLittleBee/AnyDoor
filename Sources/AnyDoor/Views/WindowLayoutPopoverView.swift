import SwiftUI
import AppKit

/// Hover popover content for the Window Layout submenu. Lists the four
/// window-layout children with their assigned hotkeys; tapping a row
/// dispatches the matching action via `PanelStore.run`.
struct WindowLayoutPopoverView: View {
    let entries: [PanelEntry]
    var onHoverChange: @MainActor (Bool) -> Void
    var onSelect: (BuiltinItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                LocalizedText(.builtinWindowLayout).font(.headline)
                Text(L(.panelAppShortcutCountSuffix, entries.count))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            if !entries.isEmpty {
                Divider().padding(.horizontal, 8)

                AdaptiveGlassEffectContainer(spacing: 2) {
                    VStack(spacing: 2) {
                        ForEach(entries) { entry in
                            if case let .builtin(item) = entry.source {
                                WindowLayoutRow(
                                    entry: entry,
                                    onSelect: { onSelect(item) }
                                )
                            }
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
        .onHoverSafe(perform: onHoverChange)
    }
}

private struct WindowLayoutRow: View {
    let entry: PanelEntry
    var onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbol)
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
            Text(entry.localizedTitle())
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let hotkey = entry.hotkey {
                HotkeyLabel(hotkey: hotkey)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .adaptiveInteractiveSurface(cornerRadius: 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHoverSafe { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
