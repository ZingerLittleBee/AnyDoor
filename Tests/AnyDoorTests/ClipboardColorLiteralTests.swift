import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

/// The swatch parser and the capture classifier have to agree: a literal filed
/// under the Color facet that the parser cannot read renders as a black card
/// labelled "color".
final class ClipboardColorLiteralTests: XCTestCase {
    private func components(
        _ text: String
    ) -> ClipboardColorLiteral.Components? {
        ClipboardColorLiteral.parse(text)
    }

    private func assertClose(
        _ actual: ClipboardColorLiteral.Components?,
        _ expected: ClipboardColorLiteral.Components,
        _ text: String,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("Expected \(text) to parse", line: line)
        }
        XCTAssertEqual(actual.red, expected.red, accuracy: 0.005, text, line: line)
        XCTAssertEqual(
            actual.green,
            expected.green,
            accuracy: 0.005,
            text,
            line: line
        )
        XCTAssertEqual(
            actual.blue,
            expected.blue,
            accuracy: 0.005,
            text,
            line: line
        )
        XCTAssertEqual(
            actual.alpha,
            expected.alpha,
            accuracy: 0.005,
            text,
            line: line
        )
    }

    func testEveryLiteralTheClassifierCallsAColorParses() {
        let literals = [
            "#F00",
            "#F00A",
            "#FF0000",
            "#FF0000AA",
            "rgb(255, 0, 0)",
            "rgba(255, 0, 0, 0.5)",
            "rgb(255 0 0 / 0.5)",
            "rgb(100%, 0%, 0%)",
            "hsl(0, 100%, 50%)",
            "hsla(0, 100%, 50%, 0.5)",
            "hsl(0deg 100% 50% / 50%)",
            "Color(red: 1.0, green: 0.0, blue: 0.0)",
            "Color(red: 1.0, green: 0.0, blue: 0.0, opacity: 0.5)",
        ]

        for literal in literals {
            XCTAssertTrue(
                ClipboardHistoryModule.inferredFacets(forExactText: literal)
                    .contains(.color),
                "Fixture \(literal) is not classified as a color"
            )
            XCTAssertNotNil(
                components(literal),
                "Classified as a color but unparsable: \(literal)"
            )
        }
    }

    func testRedIsRedInEveryNotation() {
        let red = ClipboardColorLiteral.Components(
            red: 1,
            green: 0,
            blue: 0,
            alpha: 1
        )
        let halfRed = ClipboardColorLiteral.Components(
            red: 1,
            green: 0,
            blue: 0,
            alpha: 0.5
        )
        assertClose(components("#F00"), red, "#F00")
        assertClose(components("#FF0000"), red, "#FF0000")
        assertClose(components("rgb(255, 0, 0)"), red, "rgb(255, 0, 0)")
        assertClose(components("rgb(100%, 0%, 0%)"), red, "rgb(100%, 0%, 0%)")
        assertClose(components("hsl(0, 100%, 50%)"), red, "hsl(0, 100%, 50%)")
        assertClose(
            components("Color(red: 1.0, green: 0.0, blue: 0.0)"),
            red,
            "SwiftUI form"
        )
        assertClose(components("#FF000080"), halfRed, "#FF000080")
        assertClose(components("rgb(255 0 0 / 0.5)"), halfRed, "space syntax")
        assertClose(
            components("hsl(0deg 100% 50% / 50%)"),
            halfRed,
            "hsl space syntax"
        )
        assertClose(
            components("Color(red: 1.0, green: 0.0, blue: 0.0, opacity: 0.5)"),
            halfRed,
            "SwiftUI form with opacity"
        )
    }

    func testHueUnitsAndNonRedHues() {
        let green = ClipboardColorLiteral.Components(
            red: 0,
            green: 1,
            blue: 0,
            alpha: 1
        )
        assertClose(components("hsl(120, 100%, 50%)"), green, "degrees")
        assertClose(components("hsl(120deg 100% 50%)"), green, "deg suffix")
        assertClose(
            components("hsl(0.3333turn 100% 50%)"),
            green,
            "turn suffix"
        )
        assertClose(
            components("hsl(2.0944rad 100% 50%)"),
            green,
            "rad suffix"
        )
        assertClose(
            components("#808080"),
            ClipboardColorLiteral.Components(
                red: 0.502,
                green: 0.502,
                blue: 0.502,
                alpha: 1
            ),
            "grey"
        )
    }

    func testTextTheClassifierRefusesDoesNotParse() {
        for literal in [
            "#FF000",
            "#FF00000",
            "red",
            "var(--brand)",
            "linear-gradient(to right, #f00, #00f)",
            "color(display-p3 1 0 0)",
            "rgb(255, 0, 0) trailing",
            "rgb(255, 0)",
            "hsl(0, 100%)",
            "",
        ] {
            XCTAssertFalse(
                ClipboardHistoryModule.inferredFacets(forExactText: literal)
                    .contains(.color),
                "Fixture \(literal) is unexpectedly classified as a color"
            )
            XCTAssertNil(
                components(literal),
                "Unexpectedly parsed as a color: \(literal)"
            )
        }
    }
}
