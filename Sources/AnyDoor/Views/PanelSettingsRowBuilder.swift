import Foundation

/// A single flat row in the Panel settings list: a themed section header, a
/// top-level / child entry, or a non-draggable adornment.
struct PanelSettingsRow: Identifiable {
    enum Content {
        case header(BuiltinGroup)
        case entry(PanelEntry)
        case addApp
        case brightnessRecorders
    }
    let id: String
    let content: Content
    let group: PanelDragGroup
    let opacity: Double
}

/// Pure flattening of grouped Panel entries into the ordered row list rendered
/// by `PanelSettingsView`. Kept separate from the view so the grouping +
/// collapse logic is unit-testable without SwiftUI.
///
/// Order: the headerless `.general` bucket first, then each themed group in
/// `themedOrder` preceded by a `.header` row. App-shortcut children + the
/// "add app" row follow the `appShortcuts` parent; window children follow the
/// `windowLayout` parent; brightness recorders follow the `brightness` row.
/// A collapsed themed group emits only its header; a collapsed parent emits the
/// parent row without its children.
enum PanelSettingsRowBuilder {
    static func build(
        topLevel: [PanelEntry],
        appChildren: [PanelEntry],
        windowChildren: [PanelEntry],
        themedOrder: [BuiltinGroup],
        collapsedGroups: Set<BuiltinGroup>,
        collapsedParents: Set<BuiltinItem>
    ) -> [PanelSettingsRow] {
        var rows: [PanelSettingsRow] = []

        func builtin(_ entry: PanelEntry) -> BuiltinItem? {
            if case .builtin(let item) = entry.source { return item }
            return nil
        }
        func isVisible(_ item: BuiltinItem) -> Bool {
            topLevel.first { $0.source == .builtin(item) }?.isVisible ?? true
        }

        // Emit one top-level entry plus any adornments/children that hang off it.
        func emit(_ entry: PanelEntry, dragGroup: PanelDragGroup) {
            rows.append(PanelSettingsRow(
                id: "top:\(entry.id)",
                content: .entry(entry),
                group: dragGroup,
                opacity: entry.isVisible ? 1.0 : 0.5
            ))
            switch entry.source {
            case .builtin(.appShortcuts):
                guard !collapsedParents.contains(.appShortcuts) else { return }
                let parentVisible = isVisible(.appShortcuts)
                for child in appChildren {
                    let visible = parentVisible && child.isVisible
                    rows.append(PanelSettingsRow(
                        id: "appChild:\(child.id)",
                        content: .entry(child),
                        group: .appChild,
                        opacity: visible ? 1.0 : 0.5
                    ))
                }
                rows.append(PanelSettingsRow(
                    id: "addApp",
                    content: .addApp,
                    group: .fixed,
                    opacity: parentVisible ? 1.0 : 0.5
                ))
            case .builtin(.windowLayout):
                guard !collapsedParents.contains(.windowLayout) else { return }
                let parentVisible = isVisible(.windowLayout)
                for child in windowChildren {
                    rows.append(PanelSettingsRow(
                        id: "windowChild:\(child.id)",
                        content: .entry(child),
                        group: .windowChild,
                        opacity: parentVisible ? 1.0 : 0.5
                    ))
                }
            case .builtin(.brightness):
                rows.append(PanelSettingsRow(
                    id: "brightnessRecorders",
                    content: .brightnessRecorders,
                    group: .fixed,
                    opacity: isVisible(.brightness) ? 1.0 : 0.5
                ))
            default:
                break
            }
        }

        // General bucket first, no header. topLevel is already sorted
        // group-contiguously by PanelStore, so filtering preserves order.
        for entry in topLevel where (builtin(entry).map(BuiltinGroup.group(for:)) ?? .general) == .general {
            emit(entry, dragGroup: .topLevel(.general))
        }

        // Themed sections, each preceded by a header row.
        for group in themedOrder {
            rows.append(PanelSettingsRow(
                id: "header:\(group.rawValue)",
                content: .header(group),
                group: .groupHeader,
                opacity: 1.0
            ))
            guard !collapsedGroups.contains(group) else { continue }
            for entry in topLevel where builtin(entry).map(BuiltinGroup.group(for:)) == group {
                emit(entry, dragGroup: .topLevel(group))
            }
        }

        return rows
    }
}
