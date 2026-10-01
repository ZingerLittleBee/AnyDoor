import XCTest
import PluginInterface
@testable import AnyDoor
@testable import ImageConversionPlugin

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
    }

    func testImageConversionStaysInGeneralCommandGroup() {
        XCTAssertFalse(BuiltinGroup.themedDefaultOrder.contains(where: { $0.members.contains(.imageConversion) }))
    }
}
