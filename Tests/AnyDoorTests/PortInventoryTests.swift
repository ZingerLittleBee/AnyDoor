import XCTest
@testable import AnyDoor

final class PortInventoryTests: XCTestCase {
    func testBuiltinItemPortManagerExists() {
        XCTAssertTrue(BuiltinItem.allCases.contains(.portManager))
        XCTAssertEqual(BuiltinItem.portManager.kind, .submenu)
        XCTAssertEqual(BuiltinItem.portManager.title, "端口管理")
        XCTAssertEqual(BuiltinItem.portManager.symbol, "network")
    }
}
