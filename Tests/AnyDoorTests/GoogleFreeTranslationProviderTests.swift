import XCTest
@testable import AnyDoor

final class GoogleFreeTranslationProviderTests: XCTestCase {
    func testBuildURLContainsClientAndQueryItems() throws {
        let url = GoogleFreeTranslationProvider.buildURL(
            text: "hello world",
            source: "auto",
            target: "zh-CN"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "translate.googleapis.com")
        XCTAssertEqual(components.path, "/translate_a/single")
        let items = try XCTUnwrap(components.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("client"), "gtx")
        XCTAssertEqual(value("sl"), "auto")
        XCTAssertEqual(value("tl"), "zh-CN")
        XCTAssertEqual(value("dt"), "t")
        XCTAssertEqual(value("q"), "hello world")
    }

    func testDecodeJoinsSegmentsAndReadsDetectedCode() throws {
        // Captured shape: outer[0] = array of segments [translated, original, …];
        // outer[2] = detected source language code.
        let json = #"""
        [[["你好世界","hello world",null,null,10],["再见","goodbye",null,null,3]],null,"en",null,null,null,1.0,[],[["en"]]]
        """#
        let result = try GoogleFreeTranslationProvider.decode(Data(json.utf8))
        XCTAssertEqual(result.text, "你好世界再见")
        XCTAssertEqual(result.detectedCode, "en")
    }

    func testDecodeMissingDetectedCodeIsNil() throws {
        let json = #"""
        [[["bonjour","hi",null,null,1]],null]
        """#
        let result = try GoogleFreeTranslationProvider.decode(Data(json.utf8))
        XCTAssertEqual(result.text, "bonjour")
        XCTAssertNil(result.detectedCode)
    }

    func testDecodeMalformedThrows() {
        XCTAssertThrowsError(try GoogleFreeTranslationProvider.decode(Data("{}".utf8)))
    }
}
