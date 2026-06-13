import XCTest
@testable import AnyDoor

final class UnitConversionTests: XCTestCase {
    private func first(_ query: String) -> ConversionResult? {
        UnitConversion.detect(query).first
    }

    // MARK: - Length

    func testFeetToMeters() {
        let r = first("3 ft to m")
        XCTAssertEqual(r?.display, "0.9144 m")
        XCTAssertEqual(r?.copyText, "0.9144")
        XCTAssertEqual(r?.kind, .unit)
    }

    func testKilometersToMiles() {
        XCTAssertEqual(first("1 km to mi")?.display, "0.6214 mi")
    }

    func testInchesToCentimetersPrefersToConnectorOverIn() {
        // "in" is both a unit (inch) and a connector; " to " must win.
        XCTAssertEqual(first("5 in to cm")?.display, "12.7 cm")
    }

    // MARK: - Mass

    func testKilogramsToPoundsWithInConnector() {
        XCTAssertEqual(first("100 kg in lb")?.display, "220.4623 lb")
    }

    // MARK: - Temperature (affine)

    func testFahrenheitToCelsius() {
        XCTAssertEqual(first("72 f to c")?.display, "22.2222 °C")
    }

    func testCelsiusToKelvin() {
        XCTAssertEqual(first("100 c to k")?.display, "373.15 K")
    }

    func testNegativeFahrenheitCrossover() {
        XCTAssertEqual(first("-40 c to f")?.display, "-40 °F")
    }

    // MARK: - Data

    func testGigabyteToMebibyte() {
        XCTAssertEqual(first("1 gb to mib")?.display, "953.6743 MiB")
    }

    // MARK: - Speed

    func testKilometersPerHourToMph() {
        XCTAssertEqual(first("100 km/h to mph")?.display, "62.1371 mph")
    }

    // MARK: - Guards

    func testCrossCategoryProducesNoRow() {
        XCTAssertTrue(UnitConversion.detect("3 kg to m").isEmpty)
    }

    func testMissingConnectorProducesNoRow() {
        XCTAssertTrue(UnitConversion.detect("3 ft m").isEmpty)
    }

    func testUnknownUnitProducesNoRow() {
        XCTAssertTrue(UnitConversion.detect("3 widgets to m").isEmpty)
    }

    func testCurrencyCodesAreNotUnits() {
        XCTAssertTrue(UnitConversion.detect("100 usd to eur").isEmpty)
    }

    func testDetailEchoesSource() {
        XCTAssertEqual(first("3 ft to m")?.detail, "3 ft")
    }
}
