import Foundation
import Testing
import PluginInterface
@testable import AnyDoor

/// `PanelSettingsRowBuilder` flattens Panel entries into one ordered list of rows
/// (top-level entries in `displayOrder`, with each parent's children and
/// adornments following it) that the settings list renders. These tests pin the
/// flat ordering and the parent-collapse behavior without spinning up SwiftUI.
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

    private func sampleTopLevel() -> [PanelEntry] {
        [entry(.appShortcuts), entry(.clipboardWall), entry(.brightness), entry(.muteAudio)]
    }

    @Test func emitsTopLevelEntriesFlatInGivenOrder() {
        let rows = PanelSettingsRowBuilder.build(
            topLevel: sampleTopLevel(),
            appChildren: [],
            windowChildren: [],
            collapsedParents: []
        )
        // Every row is an entry (plus the brightness recorders adornment); there
        // are no section headers, and the entries keep the input order.
        let entrySources = rows.compactMap { row -> PanelEntry.Source? in
            if case .entry(let e) = row.content { return e.source } else { return nil }
        }
        #expect(entrySources == [
            .builtin(.appShortcuts), .builtin(.clipboardWall),
            .builtin(.brightness), .builtin(.muteAudio),
        ])
        // First row carries the flat top-level drag group.
        #expect(rows.first?.group == .topLevel)
    }

    @Test func collapsedAppShortcutsParentHidesChildrenAndAddRow() {
        let expanded = PanelSettingsRowBuilder.build(
            topLevel: [entry(.appShortcuts)],
            appChildren: [appChild("Codex"), appChild("Warp")],
            windowChildren: [],
            collapsedParents: []
        )
        // Expanded: parent + 2 app children + add-app row.
        #expect(expanded.contains { $0.group == .appChild })
        #expect(expanded.contains { if case .addApp = $0.content { return true } else { return false } })

        let collapsed = PanelSettingsRowBuilder.build(
            topLevel: [entry(.appShortcuts)],
            appChildren: [appChild("Codex"), appChild("Warp")],
            windowChildren: [],
            collapsedParents: [.appShortcuts]
        )
        // Collapsed: only the parent entry remains.
        #expect(!collapsed.contains { $0.group == .appChild })
        #expect(!collapsed.contains { if case .addApp = $0.content { return true } else { return false } })
        #expect(collapsed.contains { if case .entry(let e) = $0.content { return e.source == .builtin(.appShortcuts) } else { return false } })
    }

    @Test func brightnessRecordersFollowBrightness() {
        let rows = PanelSettingsRowBuilder.build(
            topLevel: [entry(.brightness)],
            appChildren: [],
            windowChildren: [],
            collapsedParents: []
        )
        let recorderIndex = rows.firstIndex { if case .brightnessRecorders = $0.content { return true } else { return false } }
        let brightnessIndex = rows.firstIndex { if case .entry(let e) = $0.content { return e.source == .builtin(.brightness) } else { return false } }
        #expect(recorderIndex != nil && brightnessIndex != nil)
        #expect(recorderIndex! == brightnessIndex! + 1)
    }
}
