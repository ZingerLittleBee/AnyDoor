import XCTest
@testable import AnyDoor

final class HostsFileTests: XCTestCase {
    func test_parse_noMarkers_allPrefix() {
        let raw = "127.0.0.1 localhost\n255.255.255.255 broadcasthost\n"
        let p = HostsFile.parse(raw)
        XCTAssertEqual(p.prefix, raw)
        XCTAssertNil(p.managed)
        XCTAssertEqual(p.suffix, "")
    }

    func test_parse_splitsPrefixManagedSuffix() {
        let raw = [
            "127.0.0.1 localhost",
            HostsFile.beginMarker,
            "1.2.3.4 dev.example.com",
            HostsFile.endMarker,
            "9.9.9.9 after.example.com",
        ].joined(separator: "\n")
        let p = HostsFile.parse(raw)
        XCTAssertEqual(p.prefix, "127.0.0.1 localhost")
        XCTAssertEqual(p.managed, "1.2.3.4 dev.example.com")
        XCTAssertEqual(p.suffix, "9.9.9.9 after.example.com")
    }

    func test_parse_beginWithoutEnd_treatsAllAsPrefix() {
        let raw = "127.0.0.1 localhost\n\(HostsFile.beginMarker)\n1.2.3.4 x"
        let p = HostsFile.parse(raw)
        XCTAssertEqual(p.prefix, raw)
        XCTAssertNil(p.managed)
    }

    func test_compose_noActiveProfiles_removesBlock_keepsPrefix() {
        let parsed = HostsFile.Parsed(prefix: "127.0.0.1 localhost",
                                      managed: "old stuff",
                                      suffix: "")
        let out = HostsFile.compose(parsed: parsed, activeProfiles: [])
        XCTAssertFalse(out.contains(HostsFile.beginMarker))
        XCTAssertTrue(out.contains("127.0.0.1 localhost"))
    }

    func test_compose_writesBlockBetweenMarkers() {
        let parsed = HostsFile.Parsed(prefix: "127.0.0.1 localhost", managed: nil, suffix: "")
        let out = HostsFile.compose(
            parsed: parsed,
            activeProfiles: [(name: "Dev", content: "1.2.3.4 dev.example.com")]
        )
        XCTAssertTrue(out.contains(HostsFile.beginMarker))
        XCTAssertTrue(out.contains("# --- Dev ---"))
        XCTAssertTrue(out.contains("1.2.3.4 dev.example.com"))
        XCTAssertTrue(out.contains(HostsFile.endMarker))
    }

    func test_compose_preservesSuffix() {
        let parsed = HostsFile.Parsed(prefix: "127.0.0.1 localhost",
                                      managed: nil,
                                      suffix: "9.9.9.9 after.example.com")
        let out = HostsFile.compose(
            parsed: parsed,
            activeProfiles: [(name: "Dev", content: "1.2.3.4 dev")]
        )
        XCTAssertTrue(out.contains("9.9.9.9 after.example.com"))
        let endRange = try! XCTUnwrap(out.range(of: HostsFile.endMarker))
        let suffixRange = try! XCTUnwrap(out.range(of: "9.9.9.9 after.example.com"))
        XCTAssertTrue(suffixRange.lowerBound > endRange.upperBound)
    }

    func test_compose_stripsMarkerInjectionFromProfileContent() {
        let parsed = HostsFile.Parsed(prefix: "", managed: nil, suffix: "")
        let evil = "1.2.3.4 a\n\(HostsFile.beginMarker)\n\(HostsFile.endMarker)\n5.6.7.8 b"
        let out = HostsFile.compose(
            parsed: parsed,
            activeProfiles: [(name: "Evil", content: evil)]
        )
        let begins = out.components(separatedBy: HostsFile.beginMarker).count - 1
        let ends = out.components(separatedBy: HostsFile.endMarker).count - 1
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(ends, 1)
    }

    func test_compose_isIdempotent() {
        let parsed = HostsFile.Parsed(prefix: "127.0.0.1 localhost", managed: nil, suffix: "tail")
        let profiles = [(name: "A", content: "1.1.1.1 a"), (name: "B", content: "2.2.2.2 b")]
        let once = HostsFile.compose(parsed: parsed, activeProfiles: profiles)
        let twice = HostsFile.compose(parsed: HostsFile.parse(once), activeProfiles: profiles)
        XCTAssertEqual(once, twice)
    }
}
