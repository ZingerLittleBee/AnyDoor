import XCTest
@testable import AnyDoor

final class DevToolsTests: XCTestCase {
    private func output(_ query: String, toolID: String) -> String? {
        DevTools.detect(query: query).first { $0.toolID == toolID }?.output
    }

    // MARK: - Base64

    func testBase64EncodeFromKeyword() {
        XCTAssertEqual(output("base64 hello", toolID: "base64.encode"), "aGVsbG8=")
    }

    func testBase64DecodeWhenBodyIsValidBase64() {
        XCTAssertEqual(output("base64 aGVsbG8=", toolID: "base64.decode"), "hello")
    }

    func testBase64WithoutKeywordProducesNoRow() {
        XCTAssertTrue(DevTools.detect(query: "hello").isEmpty)
    }

    // MARK: - URL

    func testURLEncodeEscapesSpaceAndAmpersand() {
        XCTAssertEqual(output("url a b&c", toolID: "url.encode"), "a%20b%26c")
    }

    func testURLDecodeWhenBodyIsPercentEncoded() {
        XCTAssertEqual(output("url a%20b%26c", toolID: "url.decode"), "a b&c")
    }

    func testURLDecodeAbsentWhenNothingToDecode() {
        XCTAssertNil(output("url plain", toolID: "url.decode"))
    }

    // MARK: - JSON (auto-detected)

    func testJSONPrettySortsKeysAcrossLines() {
        guard let pretty = output(#"{"b":1,"a":2}"#, toolID: "json.pretty") else {
            return XCTFail("expected a json.pretty row")
        }
        XCTAssertTrue(pretty.contains("\n"))
        let aIndex = pretty.range(of: "\"a\"")
        let bIndex = pretty.range(of: "\"b\"")
        XCTAssertNotNil(aIndex)
        XCTAssertNotNil(bIndex)
        if let a = aIndex, let b = bIndex { XCTAssertTrue(a.lowerBound < b.lowerBound) }
    }

    func testJSONMinifyIsCompactAndSorted() {
        XCTAssertEqual(output(#"{ "b" : 1, "a" : 2 }"#, toolID: "json.minify"), #"{"a":2,"b":1}"#)
    }

    func testNonJSONTextProducesNoJSONRow() {
        XCTAssertNil(output("just text", toolID: "json.pretty"))
    }

    // MARK: - Hash (known vectors for "abc")

    func testMD5KnownVector() {
        XCTAssertEqual(output("md5 abc", toolID: "hash.md5"), "900150983cd24fb0d6963f7d28e17f72")
    }

    func testSHA1KnownVector() {
        XCTAssertEqual(output("sha1 abc", toolID: "hash.sha1"), "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    func testSHA256KnownVector() {
        XCTAssertEqual(
            output("sha256 abc", toolID: "hash.sha256"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: - Unix timestamp -> date (auto-detected)

    private static let utc = TimeZone(identifier: "UTC")!

    func testTimestampSecondsRendersISO() {
        let rows = DevTools.detect(query: "1700000000", timeZone: Self.utc)
        XCTAssertEqual(rows.first { $0.toolID == "ts.iso" }?.output, "2023-11-14T22:13:20Z")
    }

    func testTimestampMillisRendersISO() {
        let rows = DevTools.detect(query: "1700000000000", timeZone: Self.utc)
        XCTAssertEqual(rows.first { $0.toolID == "ts.iso" }?.output, "2023-11-14T22:13:20Z")
    }

    func testTimestampUTCRow() {
        let rows = DevTools.detect(query: "1700000000", timeZone: Self.utc)
        XCTAssertEqual(rows.first { $0.toolID == "ts.utc" }?.output, "2023-11-14 22:13:20")
    }

    func testShortNumberIsNotATimestamp() {
        XCTAssertTrue(DevTools.detect(query: "8080").isEmpty)
        XCTAssertTrue(DevTools.detect(query: "42").isEmpty)
    }

    // MARK: - Scope (search-bar badge) evaluation

    func testScopeKeywordParsing() {
        XCTAssertEqual(DevToolScope(keyword: "base64"), .base64)
        XCTAssertEqual(DevToolScope(keyword: "SHA256"), .sha256)
        XCTAssertNil(DevToolScope(keyword: "json"))
        XCTAssertNil(DevToolScope(keyword: "xyz"))
    }

    func testScopeBadgeLabels() {
        XCTAssertEqual(DevToolScope.base64.badgeLabel, "Base64")
        XCTAssertEqual(DevToolScope.url.badgeLabel, "URL")
        XCTAssertEqual(DevToolScope.sha1.badgeLabel, "SHA-1")
        XCTAssertEqual(DevToolScope.sha256.badgeLabel, "SHA-256")
    }

    func testScopeResultsBase64BothDirections() {
        let rows = DevTools.results(scope: .base64, body: "aGVsbG8=")
        XCTAssertEqual(rows.first { $0.toolID == "base64.encode" }?.output, "YUdWc2JHOD0=")
        XCTAssertEqual(rows.first { $0.toolID == "base64.decode" }?.output, "hello")
    }

    func testScopeResultsHash() {
        XCTAssertEqual(
            DevTools.results(scope: .md5, body: "abc").first?.output,
            "900150983cd24fb0d6963f7d28e17f72"
        )
        XCTAssertEqual(
            DevTools.results(scope: .sha256, body: "abc").first?.output,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testScopeResultsURL() {
        XCTAssertEqual(
            DevTools.results(scope: .url, body: "a b&c").first { $0.toolID == "url.encode" }?.output,
            "a%20b%26c"
        )
    }

    func testScopeEmptyBodyProducesNoRows() {
        XCTAssertTrue(DevTools.results(scope: .base64, body: "   ").isEmpty)
        XCTAssertTrue(DevTools.results(scope: .md5, body: "").isEmpty)
    }
}
