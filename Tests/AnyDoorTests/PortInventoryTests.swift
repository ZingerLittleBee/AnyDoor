import XCTest
@testable import AnyDoor

final class PortInventoryTests: XCTestCase {
    func testBuiltinItemPortManagerExists() {
        XCTAssertTrue(BuiltinItem.allCases.contains(.portManager))
        XCTAssertEqual(BuiltinItem.portManager.kind, .submenu)
        XCTAssertEqual(BuiltinItem.portManager.title, "端口管理")
        XCTAssertEqual(BuiltinItem.portManager.symbol, "network")
    }

    func testPortRecordIdComposition() {
        let r = PortRecord(
            port: 3000,
            pid: 67035,
            processName: "node",
            executablePath: nil,
            commandLine: nil,
            binds: [PortBind(address: "*", family: .ipv4)]
        )
        XCTAssertEqual(r.id, "67035-3000")
    }

    func testSignalResultEquatable() {
        XCTAssertEqual(SignalResult.success, SignalResult.success)
        XCTAssertEqual(SignalResult.failure(.EPERM), SignalResult.failure(.EPERM))
        XCTAssertNotEqual(SignalResult.success, SignalResult.failure(.EPERM))
    }
}
