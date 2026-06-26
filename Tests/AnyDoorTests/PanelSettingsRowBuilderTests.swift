import Foundation
import Testing
@testable import AnyDoor

/// `PanelSettingsRowBuilder` flattens grouped Panel entries into one ordered
/// list of rows (with injected section headers + collapse handling) that the
/// settings `List` renders. These tests pin header placement and the two
/// collapse behaviors without spinning up SwiftUI.
struct PanelSettingsRowBuilderTests {

    private func entry(_ item: BuiltinItem, visible: Bool = true) -> PanelEntry {
        PanelEntry(
            id: PanelEntry.id(for: .builtin(item)),
            source: .builtin(item),
            displayOrder: item.defaultOrder,
            isVisible: visible,
            hotkey: nil,
            title: "",
            subtitle: nil,
            symbol: item.symbol,
            kind: item.kind,
            toggleState: nil,
            permission: .notRequired
        )
    }

    private func appChild(_ name: String) -> PanelEntry {
        PanelEntry(
            id: "appChild:\(name)",
            source: .appShortcut(UUID()),
            displayOrder: 100,
            isVisible: true,
            hotkey: nil,
            title: name,
            subtitle: nil,
            symbol: "app.fill",
            kind: .submenu,
            toggleState: nil,
            permission: .notRequired
        )
    }

    /// general: appShortcuts, clipboardWall ; togglesAppearance: brightness, muteAudio
    private func sampleTopLevel() -> [PanelEntry] {
        [entry(.appShortcuts), entry(.clipboardWall), entry(.brightness), entry(.muteAudio)]
    }

    @Test func generalEntriesLeadWithoutAHeader() {
        let rows = PanelSettingsRowBuilder.build(
            topLevel: sampleTopLevel(),
            appChildren: [],
            windowChildren: [],
            themedOrder: [.togglesAppearance],
            collapsedGroups: [],
            collapsedParents: []
        )
        // First row is the general appShortcuts entry, not a header.
        guard case .entry(let first) = rows.first?.content else {
            Issue.record("first row should be an entry"); return
        }
        #expect(first.source == .builtin(.appShortcuts))
        #expect(rows.first?.group == .topLevel(.general))
        // Exactly one header exists, for togglesAppearance.
        let headers = rows.compactMap { row -> BuiltinGroup? in
            if case .header(let g) = row.content { return g } else { return nil }
        }
        #expect(headers == [.togglesAppearance])
    }

    @Test func collapsedThemedGroupEmitsHeaderOnly() {
        let rows = PanelSettingsRowBuilder.build(
            topLevel: sampleTopLevel(),
            appChildren: [],
            windowChildren: [],
            themedOrder: [.togglesAppearance],
            collapsedGroups: [.togglesAppearance],
            collapsedParents: []
        )
        // The header is present but neither brightness nor muteAudio rows follow.
        #expect(rows.contains { if case .header(.togglesAppearance) = $0.content { return true } else { return false } })
        let toggleEntries = rows.contains { row in
            if case .entry(let e) = row.content, case .builtin(let i) = e.source {
                return BuiltinGroup.group(for: i) == .togglesAppearance
            }
            return false
        }
        #expect(!toggleEntries)
    }

    @Test func collapsedAppShortcutsParentHidesChildrenAndAddRow() {
        let expanded = PanelSettingsRowBuilder.build(
            topLevel: [entry(.appShortcuts)],
            appChildren: [appChild("Codex"), appChild("Warp")],
            windowChildren: [],
            themedOrder: [],
            collapsedGroups: [],
            collapsedParents: []
        )
        // Expanded: parent + 2 app children + add-app row.
        #expect(expanded.contains { $0.group == .appChild })
        #expect(expanded.contains { if case .addApp = $0.content { return true } else { return false } })

        let collapsed = PanelSettingsRowBuilder.build(
            topLevel: [entry(.appShortcuts)],
            appChildren: [appChild("Codex"), appChild("Warp")],
            windowChildren: [],
            themedOrder: [],
            collapsedGroups: [],
            collapsedParents: [.appShortcuts]
        )
        // Collapsed: only the parent entry remains.
        #expect(!collapsed.contains { $0.group == .appChild })
        #expect(!collapsed.contains { if case .addApp = $0.content { return true } else { return false } })
        #expect(collapsed.contains { if case .entry(let e) = $0.content { return e.source == .builtin(.appShortcuts) } else { return false } })
    }

    @Test func brightnessRecordersFollowBrightnessInThemedGroup() {
        let rows = PanelSettingsRowBuilder.build(
            topLevel: [entry(.brightness)],
            appChildren: [],
            windowChildren: [],
            themedOrder: [.togglesAppearance],
            collapsedGroups: [],
            collapsedParents: []
        )
        let recorderIndex = rows.firstIndex { if case .brightnessRecorders = $0.content { return true } else { return false } }
        let brightnessIndex = rows.firstIndex { if case .entry(let e) = $0.content { return e.source == .builtin(.brightness) } else { return false } }
        #expect(recorderIndex != nil && brightnessIndex != nil)
        #expect(recorderIndex! == brightnessIndex! + 1)
    }
}
