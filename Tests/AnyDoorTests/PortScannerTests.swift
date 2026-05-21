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

    func testParseMultiPort() throws {
        let raw = try fixture("lsof-multi-port")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.port), [80, 443, 5432])
        for r in records { XCTAssertEqual(r.pid, 898); XCTAssertEqual(r.processName, "OrbStack Helper") }
    }

    func testParseDualStackMergesBinds() throws {
        let raw = try fixture("lsof-dual-stack")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.pid, 75837)
        XCTAssertEqual(r.port, 5000)
        XCTAssertEqual(r.binds.count, 2)
        XCTAssertEqual(Set(r.binds.map(\.family)), Set([.ipv4, .ipv6]))
        // Ordering: IPv4 first then IPv6 (sorted by rawValue).
        XCTAssertEqual(r.binds.map(\.family), [.ipv4, .ipv6])
    }

    func testParseMultiBindSamePort() throws {
        let raw = try fixture("lsof-multi-bind")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.binds.count, 2)
        XCTAssertEqual(Set(r.binds.map(\.address)), Set(["127.0.0.1", "0.0.0.0"]))
    }

    func testParseIPv6ZoneId() throws {
        let raw = try fixture("lsof-ipv6-zone")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.port, 1234)
        XCTAssertEqual(r.binds, [PortBind(address: "fe80::1%en0", family: .ipv6)])
    }

    func testParseCommandWithSpaces() throws {
        let raw = try fixture("lsof-command-spaces")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].processName, "Google Chrome Helper")
    }

    func testParseEscapeSequence() throws {
        let raw = try fixture("lsof-escape")
        let records = try parseLsofOutput(raw)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].processName, "weird name")
    }
}
