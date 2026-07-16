import XCTest
import PluginInterface
@testable import AnyDoor

final class BuiltinItemImageConversionTests: XCTestCase {
    func testImageConversionCaseExists() {
        XCTAssertNotNil(BuiltinItem(rawValue: "imageConversion"))
        XCTAssertTrue(BuiltinItem.allCases.contains(.imageConversion))
    }

    func testImageConversionCatalogMetadata() {
        XCTAssertEqual(BuiltinItem.imageConversion.kind, .action)
        XCTAssertEqual(BuiltinItem.imageConversion.titleKey, .builtinImageConversion)
        XCTAssertEqual(BuiltinItem.imageConversion.symbol, "photo.on.rectangle")
        XCTAssertEqual(BuiltinItem.imageConversion.defaultOrder, 986)
        XCTAssertTrue(BuiltinItem.imageConversion.defaultVisibility)
        XCTAssertFalse(BuiltinItem.imageConversion.requiresAutomation)
    }

    func testImageConversionStaysInGeneralCommandGroup() {
        XCTAssertEqual(BuiltinGroup.group(for: .imageConversion), .general)
    }
}
