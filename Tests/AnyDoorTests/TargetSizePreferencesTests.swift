import XCTest

@testable import AnyDoor

final class TargetSizePreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TargetSizePreferencesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private let lossyFormats: [ImageConversionFormat] = [.jpeg, .heic, .avif]

    // MARK: - Defaults

    func testModeDefaultsToQuality() {
        XCTAssertEqual(ImageConversionPreferences.mode(defaults: defaults), .quality)
    }

    func testTargetSizeFormatDefaultsToJPEG() {
        XCTAssertEqual(
            ImageConversionPreferences.targetSizeFormat(availableFormats: lossyFormats, defaults: defaults),
            .jpeg
        )
    }

    func testTargetSizeLimitDefaultsToOneMegabyte() {
        let limit = ImageConversionPreferences.targetSizeLimit(defaults: defaults)
        XCTAssertEqual(limit.bytes, 1_000_000)
        XCTAssertEqual(limit.unit, .mb)
    }

    func testAllowResizeDefaultsToFalse() {
        XCTAssertFalse(ImageConversionPreferences.targetSizeAllowResize(defaults: defaults))
    }

    func testTransparencyBackgroundDefaultsToWhite() {
        XCTAssertEqual(
            ImageConversionPreferences.transparencyBackgroundHex(defaults: defaults),
            "#FFFFFF"
        )
    }

    // MARK: - Mode fallback

    func testGarbageModeFallsBackToQuality() {
        defaults.set("wat", forKey: ImageConversionPreferences.modeKey)
        XCTAssertEqual(ImageConversionPreferences.mode(defaults: defaults), .quality)
    }

    func testModeRoundTrips() {
        ImageConversionPreferences.setMode(.targetSize, defaults: defaults)
        XCTAssertEqual(ImageConversionPreferences.mode(defaults: defaults), .targetSize)
    }

    // MARK: - Target format fallback

    func testUnavailableStoredFormatFallsBackToJPEG() {
        defaults.set(ImageConversionFormat.heic.rawValue, forKey: ImageConversionPreferences.targetSizeFormatKey)
        // HEIC is stored but not available; JPEG is available so it wins.
        XCTAssertEqual(
            ImageConversionPreferences.targetSizeFormat(availableFormats: [.jpeg, .avif], defaults: defaults),
            .jpeg
        )
    }

    func testLosslessStoredFormatFallsBackToJPEG() {
        defaults.set(ImageConversionFormat.png.rawValue, forKey: ImageConversionPreferences.targetSizeFormatKey)
        XCTAssertEqual(
            ImageConversionPreferences.targetSizeFormat(availableFormats: [.png, .jpeg, .heic], defaults: defaults),
            .jpeg
        )
    }

    func testFallsBackToFirstLossyWhenJPEGUnavailable() {
        defaults.set("garbage", forKey: ImageConversionPreferences.targetSizeFormatKey)
        XCTAssertEqual(
            ImageConversionPreferences.targetSizeFormat(availableFormats: [.png, .heic, .avif], defaults: defaults),
            .heic
        )
    }

    func testFallsBackToJPEGWhenNoLossyAvailable() {
        defaults.set("garbage", forKey: ImageConversionPreferences.targetSizeFormatKey)
        XCTAssertEqual(
            ImageConversionPreferences.targetSizeFormat(availableFormats: [.png, .tiff], defaults: defaults),
            .jpeg
        )
    }

    func testValidStoredFormatIsReturned() {
        defaults.set(ImageConversionFormat.avif.rawValue, forKey: ImageConversionPreferences.targetSizeFormatKey)
        XCTAssertEqual(
            ImageConversionPreferences.targetSizeFormat(availableFormats: lossyFormats, defaults: defaults),
            .avif
        )
    }

    func testSetTargetSizeFormatNormalizesLosslessToDefault() {
        ImageConversionPreferences.setTargetSizeFormat(.png, defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: ImageConversionPreferences.targetSizeFormatKey),
            ImageConversionFormat.jpeg.rawValue
        )
    }

    func testSetTargetSizeFormatRoundTrips() {
        ImageConversionPreferences.setTargetSizeFormat(.heic, defaults: defaults)
        XCTAssertEqual(
            ImageConversionPreferences.targetSizeFormat(availableFormats: lossyFormats, defaults: defaults),
            .heic
        )
    }

    // MARK: - Target limit fallback

    func testNegativeBytesFallBackToDefault() {
        defaults.set(-5, forKey: ImageConversionPreferences.targetSizeBytesKey)
        defaults.set("kb", forKey: ImageConversionPreferences.targetSizeUnitKey)
        let limit = ImageConversionPreferences.targetSizeLimit(defaults: defaults)
        XCTAssertEqual(limit.bytes, 1_000_000)
        // Unit is valid and must survive the bytes fallback.
        XCTAssertEqual(limit.unit, .kb)
    }

    func testZeroBytesFallBackToDefault() {
        defaults.set(0, forKey: ImageConversionPreferences.targetSizeBytesKey)
        XCTAssertEqual(ImageConversionPreferences.targetSizeLimit(defaults: defaults).bytes, 1_000_000)
    }

    func testOverflowBytesFallBackToDefault() {
        defaults.set(Int(TargetSizeLimit.maxBytes) + 1, forKey: ImageConversionPreferences.targetSizeBytesKey)
        XCTAssertEqual(ImageConversionPreferences.targetSizeLimit(defaults: defaults).bytes, 1_000_000)
    }

    func testMaxBytesIsAccepted() {
        defaults.set(Int(TargetSizeLimit.maxBytes), forKey: ImageConversionPreferences.targetSizeBytesKey)
        XCTAssertEqual(
            ImageConversionPreferences.targetSizeLimit(defaults: defaults).bytes,
            TargetSizeLimit.maxBytes
        )
    }

    func testUnknownUnitFallsBackToMB() {
        defaults.set("gb", forKey: ImageConversionPreferences.targetSizeUnitKey)
        XCTAssertEqual(ImageConversionPreferences.targetSizeLimit(defaults: defaults).unit, .mb)
    }

    func testBadUnitKeepsValidBytesIndependently() {
        defaults.set(250_000, forKey: ImageConversionPreferences.targetSizeBytesKey)
        defaults.set("nonsense", forKey: ImageConversionPreferences.targetSizeUnitKey)
        let limit = ImageConversionPreferences.targetSizeLimit(defaults: defaults)
        // A bad unit must not reset the valid byte count.
        XCTAssertEqual(limit.bytes, 250_000)
        XCTAssertEqual(limit.unit, .mb)
    }

    func testSetTargetSizeLimitRoundTrips() {
        ImageConversionPreferences.setTargetSizeLimit(TargetSizeLimit(bytes: 500_000, unit: .kb), defaults: defaults)
        let limit = ImageConversionPreferences.targetSizeLimit(defaults: defaults)
        XCTAssertEqual(limit.bytes, 500_000)
        XCTAssertEqual(limit.unit, .kb)
    }

    func testSetTargetSizeLimitClampsBytes() {
        ImageConversionPreferences.setTargetSizeLimit(TargetSizeLimit(bytes: 0, unit: .mb), defaults: defaults)
        XCTAssertEqual(ImageConversionPreferences.targetSizeLimit(defaults: defaults).bytes, 1)

        ImageConversionPreferences.setTargetSizeLimit(
            TargetSizeLimit(bytes: TargetSizeLimit.maxBytes + 10, unit: .mb),
            defaults: defaults
        )
        XCTAssertEqual(
            ImageConversionPreferences.targetSizeLimit(defaults: defaults).bytes,
            TargetSizeLimit.maxBytes
        )
    }

    // MARK: - Allow resize

    func testAllowResizeRoundTrips() {
        ImageConversionPreferences.setTargetSizeAllowResize(true, defaults: defaults)
        XCTAssertTrue(ImageConversionPreferences.targetSizeAllowResize(defaults: defaults))
        ImageConversionPreferences.setTargetSizeAllowResize(false, defaults: defaults)
        XCTAssertFalse(ImageConversionPreferences.targetSizeAllowResize(defaults: defaults))
    }

    // MARK: - Transparency background fallback

    func testHexWithoutHashFallsBackToWhite() {
        defaults.set("FFFFFF", forKey: ImageConversionPreferences.transparencyBackgroundHexKey)
        XCTAssertEqual(ImageConversionPreferences.transparencyBackgroundHex(defaults: defaults), "#FFFFFF")
    }

    func testShortHexFallsBackToWhite() {
        defaults.set("#FFF", forKey: ImageConversionPreferences.transparencyBackgroundHexKey)
        XCTAssertEqual(ImageConversionPreferences.transparencyBackgroundHex(defaults: defaults), "#FFFFFF")
    }

    func testNonHexDigitsFallBackToWhite() {
        defaults.set("#GGGGGG", forKey: ImageConversionPreferences.transparencyBackgroundHexKey)
        XCTAssertEqual(ImageConversionPreferences.transparencyBackgroundHex(defaults: defaults), "#FFFFFF")
    }

    func testTooLongHexFallsBackToWhite() {
        defaults.set("#FFFFFFF", forKey: ImageConversionPreferences.transparencyBackgroundHexKey)
        XCTAssertEqual(ImageConversionPreferences.transparencyBackgroundHex(defaults: defaults), "#FFFFFF")
    }

    func testValidHexIsReturned() {
        defaults.set("#123ABC", forKey: ImageConversionPreferences.transparencyBackgroundHexKey)
        XCTAssertEqual(ImageConversionPreferences.transparencyBackgroundHex(defaults: defaults), "#123ABC")
    }

    func testLowercaseHexIsStoredAndReadUppercase() {
        ImageConversionPreferences.setTransparencyBackgroundHex("#a1b2c3", defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: ImageConversionPreferences.transparencyBackgroundHexKey),
            "#A1B2C3"
        )
        XCTAssertEqual(ImageConversionPreferences.transparencyBackgroundHex(defaults: defaults), "#A1B2C3")
    }

    func testSetInvalidHexStoresDefault() {
        ImageConversionPreferences.setTransparencyBackgroundHex("nope", defaults: defaults)
        XCTAssertEqual(
            defaults.string(forKey: ImageConversionPreferences.transparencyBackgroundHexKey),
            "#FFFFFF"
        )
    }

    // MARK: - Registry round-trip

    func testRegistryCarriesAllSixNewKeys() {
        ImageConversionPreferences.setMode(.targetSize, defaults: defaults)
        ImageConversionPreferences.setTargetSizeFormat(.heic, defaults: defaults)
        ImageConversionPreferences.setTargetSizeLimit(TargetSizeLimit(bytes: 750_000, unit: .kb), defaults: defaults)
        ImageConversionPreferences.setTargetSizeAllowResize(true, defaults: defaults)
        ImageConversionPreferences.setTransparencyBackgroundHex("#101010", defaults: defaults)

        let snapshot = SyncSettingsRegistry.read(from: defaults)

        XCTAssertEqual(snapshot[ImageConversionPreferences.modeKey], .string("targetSize"))
        XCTAssertEqual(snapshot[ImageConversionPreferences.targetSizeFormatKey], .string("heic"))
        XCTAssertEqual(snapshot[ImageConversionPreferences.targetSizeBytesKey], .int(750_000))
        XCTAssertEqual(snapshot[ImageConversionPreferences.targetSizeUnitKey], .string("kb"))
        XCTAssertEqual(snapshot[ImageConversionPreferences.targetSizeAllowResizeKey], .bool(true))
        XCTAssertEqual(snapshot[ImageConversionPreferences.transparencyBackgroundHexKey], .string("#101010"))

        let destinationSuite = "TargetSizePreferencesTests-dest-\(UUID().uuidString)"
        let destination = UserDefaults(suiteName: destinationSuite)!
        destination.removePersistentDomain(forName: destinationSuite)
        defer { destination.removePersistentDomain(forName: destinationSuite) }

        let applied = SyncSettingsRegistry.write(snapshot, to: destination)
        XCTAssertGreaterThanOrEqual(applied, 6)

        XCTAssertEqual(ImageConversionPreferences.mode(defaults: destination), .targetSize)
        XCTAssertEqual(
            ImageConversionPreferences.targetSizeFormat(availableFormats: lossyFormats, defaults: destination),
            .heic
        )
        let limit = ImageConversionPreferences.targetSizeLimit(defaults: destination)
        XCTAssertEqual(limit.bytes, 750_000)
        XCTAssertEqual(limit.unit, .kb)
        XCTAssertTrue(ImageConversionPreferences.targetSizeAllowResize(defaults: destination))
        XCTAssertEqual(ImageConversionPreferences.transparencyBackgroundHex(defaults: destination), "#101010")
    }
}
