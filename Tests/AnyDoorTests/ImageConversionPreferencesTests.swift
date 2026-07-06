import XCTest
@testable import AnyDoor

final class ImageConversionPreferencesTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "ImageConversionPreferences.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testQualityDefaultsToEightyFiveWhenUnset() {
        let defaults = makeDefaults()
        XCTAssertEqual(ImageConversionPreferences.qualityPercent(defaults: defaults), 85)
    }

    func testQualityRoundTripsWithinRange() {
        let defaults = makeDefaults()
        ImageConversionPreferences.setQualityPercent(42, defaults: defaults)
        XCTAssertEqual(ImageConversionPreferences.qualityPercent(defaults: defaults), 42)
    }

    func testSetQualityClampsToRange() {
        let defaults = makeDefaults()
        ImageConversionPreferences.setQualityPercent(0, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: ImageConversionPreferences.qualityKey), 1)
        ImageConversionPreferences.setQualityPercent(9_999, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: ImageConversionPreferences.qualityKey), 100)
    }

    func testOutOfRangeStoredValueFallsBackToDefault() {
        let defaults = makeDefaults()
        // A garbage value written directly (e.g. a corrupted import) must not reach
        // the encoder as-is.
        defaults.set(500, forKey: ImageConversionPreferences.qualityKey)
        XCTAssertEqual(ImageConversionPreferences.qualityPercent(defaults: defaults), 85)
        defaults.set(-3, forKey: ImageConversionPreferences.qualityKey)
        XCTAssertEqual(ImageConversionPreferences.qualityPercent(defaults: defaults), 85)
    }

    func testTargetFormatFallsBackToFirstAvailableWhenStoredIsUnsupported() {
        let defaults = makeDefaults()
        ImageConversionPreferences.setTargetFormat(.avif, defaults: defaults)
        let resolved = ImageConversionPreferences.targetFormat(
            availableFormats: [.png, .jpeg],
            defaults: defaults
        )
        XCTAssertEqual(resolved, .png)
    }

    func testLossinessMatchesFormat() {
        XCTAssertTrue(ImageConversionFormat.jpeg.isLossy)
        XCTAssertTrue(ImageConversionFormat.heic.isLossy)
        XCTAssertTrue(ImageConversionFormat.avif.isLossy)
        for format in [ImageConversionFormat.png, .tiff, .gif, .bmp, .pdf, .ico] {
            XCTAssertFalse(format.isLossy, "\(format) must be lossless")
        }
    }
}
