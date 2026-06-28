import Foundation

/// A single flat row in the Panel settings list: a top-level / child entry, or a
/// non-draggable adornment.
struct PanelSettingsRow: Identifiable {
    enum Content {
        case entry(PanelEntry)
        case addApp
        case brightnessRecorders
    }
    let id: String
    let content: Content
    let group: PanelDragGroup
    let opacity: Double
}

/// Pure flattening of Panel entries into the ordered row list rendered by
/// `PanelSettingsView`. Kept separate from the view so the (parent) collapse
/// logic is unit-testable without SwiftUI.
///
/// Order: top-level entries in the order given (already sorted by `displayOrder`
/// in `PanelStore`). App-shortcut children + the "add app" row follow the
/// `appShortcuts` parent; window children follow the `windowLayout` parent;
/// brightness recorders follow the `brightness` row. A collapsed parent emits the
/// parent row without its children.
enum PanelSettingsRowBuilder {
    static func build(
        topLevel: [PanelEntry],
        appChildren: [PanelEntry],
        windowChildren: [PanelEntry],
        collapsedParents: Set<BuiltinItem>
    ) -> [PanelSettingsRow] {
        var rows: [PanelSettingsRow] = []

        func isVisible(_ item: BuiltinItem) -> Bool {
            topLevel.first { $0.source == .builtin(item) }?.isVisible ?? true
        }

        for entry in topLevel {
            rows.append(PanelSettingsRow(
                id: "top:\(entry.id)",
                content: .entry(entry),
                group: .topLevel,
                opacity: entry.isVisible ? 1.0 : 0.5
            ))
            switch entry.source {
            case .builtin(.appShortcuts):
                guard !collapsedParents.contains(.appShortcuts) else { continue }
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
                guard !collapsedParents.contains(.windowLayout) else { continue }
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

        return rows
    }
}
