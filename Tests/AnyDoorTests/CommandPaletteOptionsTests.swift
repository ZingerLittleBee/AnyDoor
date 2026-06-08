import XCTest
@testable import AnyDoor

final class CommandPaletteOptionsTests: XCTestCase {
    @MainActor
    func testPaletteOptionSourceMakesStableID() {
        let source = PanelEntry.Source.paletteOption(id: "keepAwake.15")
        XCTAssertEqual(PanelEntry.id(for: source), "option:keepAwake.15")
    }

    @MainActor
    func testPaletteOptionLocalizedTitleReturnsStoredTitle() {
        let entry = PanelEntry(
            id: "option:x",
            source: .paletteOption(id: "x"),
            displayOrder: 0,
            isVisible: true,
            hotkey: nil,
            title: "30 minutes",
            subtitle: nil,
            symbol: "clock",
            kind: .action,
            toggleState: nil,
            permission: .notRequired
        )
        XCTAssertEqual(entry.localizedTitle(), "30 minutes")
    }
}
