import XCTest
@testable import AnyDoor

final class PortScannerTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "txt") else {
            XCTFail("fixture \(name).txt not found in test bundle")
            throw XCTSkip("missing fixture")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParseSingleIPv4Listener() throws {
        let raw = try fixture("lsof-single-ipv4")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.pid, 67035)
        XCTAssertEqual(r.port, 3000)
        XCTAssertEqual(r.processName, "node")
        XCTAssertEqual(r.binds, [PortBind(address: "*", family: .ipv4)])
    }
}
