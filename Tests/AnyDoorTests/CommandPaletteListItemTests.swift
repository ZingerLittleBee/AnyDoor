import XCTest
@testable import AnyDoor

/// The root list renders one flat `ForEach` over these items. Rows and sections
/// reorder as the query changes; keeping every row in one identity space is
/// what stops a moved row's old rendering from staying painted as selected.
final class CommandPaletteListItemTests: XCTestCase {
    private func entry(_ bundleID: String, title: String) -> PanelEntry {
        PanelEntry.paletteRow(
            source: .installedApp(bundleID: bundleID, path: "/Applications/\(title).app"),
            displayOrder: 0,
            title: title,
            symbol: "app.fill",
            kind: .submenu
        )
    }

    func testFlattenEmitsHeaderThenItsRows() {
        let sections = [
            CommandPaletteSection(
                rawTitleKey: "commandPalette.section.commands",
                entries: [entry("cc.musedam.sync", title: "MuseDAM")]
            ),
            CommandPaletteSection(
                rawTitleKey: "commandPalette.section.applications",
                entries: [entry("com.electron.musedam-publisher", title: "MuseDAM Publisher")]
            ),
        ]

        let items = CommandPalettePicker.CommandPaletteListItem.flatten(sections)

        XCTAssertEqual(items.map(\.id), [
            "header:commandPalette.section.commands",
            "installedApp:cc.musedam.sync",
            "header:commandPalette.section.applications",
            "installedApp:com.electron.musedam-publisher",
        ])
    }

    /// Duplicate ids in the `ForEach` would put two rows in the same identity,
    /// which is the failure mode the flattening exists to avoid.
    func testFlattenedIdentitiesAreUniqueAcrossSections() {
        let sections = [
            CommandPaletteSection(
                rawTitleKey: "commandPalette.section.commands",
                entries: [entry("a", title: "A"), entry("b", title: "B")]
            ),
            CommandPaletteSection(
                rawTitleKey: "commandPalette.section.applications",
                entries: [entry("c", title: "C")]
            ),
        ]

        let ids = CommandPalettePicker.CommandPaletteListItem.flatten(sections).map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
