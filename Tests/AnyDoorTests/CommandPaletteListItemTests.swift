import XCTest
@testable import AnyDoor

/// The root list renders one flat `ForEach` over these items. A section header
/// repeats once per rank tier, so the same entry moves between sections as the
/// query changes; keeping every row in one identity space is what stops the
/// row it left behind from staying painted as selected.
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
                rawTitleKey: "commandPalette.section.applications",
                entries: [entry("cc.musedam.sync", title: "MuseDAM")],
                identitySuffix: "exact"
            ),
            CommandPaletteSection(
                rawTitleKey: "commandPalette.section.applications",
                entries: [entry("com.electron.musedam-publisher", title: "MuseDAM Publisher")],
                identitySuffix: "prefix"
            ),
        ]

        let items = CommandPalettePicker.CommandPaletteListItem.flatten(sections)

        XCTAssertEqual(items.map(\.id), [
            "header:commandPalette.section.applications#exact",
            "installedApp:cc.musedam.sync",
            "header:commandPalette.section.applications#prefix",
            "installedApp:com.electron.musedam-publisher",
        ])
    }

    /// Duplicate ids in the `ForEach` would put two rows in the same identity,
    /// which is the failure mode the flattening exists to avoid.
    func testFlattenedIdentitiesAreUniqueAcrossRepeatedSectionTitles() {
        let sections = [
            CommandPaletteSection(
                rawTitleKey: "commandPalette.section.applications",
                entries: [entry("a", title: "A"), entry("b", title: "B")],
                identitySuffix: "exact"
            ),
            CommandPaletteSection(
                rawTitleKey: "commandPalette.section.applications",
                entries: [entry("c", title: "C")],
                identitySuffix: "prefix"
            ),
        ]

        let ids = CommandPalettePicker.CommandPaletteListItem.flatten(sections).map(\.id)

        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
