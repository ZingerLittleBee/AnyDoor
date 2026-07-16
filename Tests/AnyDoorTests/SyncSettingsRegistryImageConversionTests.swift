import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

final class SyncSettingsRegistryImageConversionTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "SyncRegistryImageConversion.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testImageConversionKeysAreWhitelisted() {
        let keys = Set(SyncSettingsRegistry.entries.map(\.key))
        XCTAssertTrue(keys.contains("imageConversion.targetFormat"))
        XCTAssertTrue(keys.contains("imageConversion.quality"))
    }

    func testImageConversionKeysHaveExpectedTypes() {
        let byKey = Dictionary(uniqueKeysWithValues: SyncSettingsRegistry.entries.map { ($0.key, $0.type) })
        XCTAssertEqual(byKey["imageConversion.targetFormat"], .string)
        XCTAssertEqual(byKey["imageConversion.quality"], .int)
    }

    func testImageConversionSettingsRoundTripThroughRegistry() {
        let source = makeDefaults()
        ImageConversionPreferences.setTargetFormat(.jpeg, defaults: source)
        ImageConversionPreferences.setQualityPercent(37, defaults: source)

        let captured = SyncSettingsRegistry.read(from: source)
        XCTAssertEqual(captured["imageConversion.targetFormat"], .string("jpeg"))
        XCTAssertEqual(captured["imageConversion.quality"], .int(37))

        let destination = makeDefaults()
        let applied = SyncSettingsRegistry.write(captured, to: destination)
        XCTAssertEqual(applied, 2)

        XCTAssertEqual(
            ImageConversionPreferences.targetFormat(availableFormats: [.png, .jpeg], defaults: destination),
            .jpeg
        )
        XCTAssertEqual(ImageConversionPreferences.qualityPercent(defaults: destination), 37)
    }
}
