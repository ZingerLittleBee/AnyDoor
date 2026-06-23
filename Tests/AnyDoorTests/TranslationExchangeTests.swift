import XCTest
@testable import AnyDoor

final class TranslationExchangeTests: XCTestCase {
    func testRequestEquatable() {
        let a = TranslationRequest(text: "hi", source: nil, target: .english)
        let b = TranslationRequest(text: "hi", source: nil, target: .english)
        XCTAssertEqual(a, b)

        let c = TranslationRequest(text: "hi", source: .simplifiedChinese, target: .english)
        XCTAssertNotEqual(a, c)
    }

    func testRequestNilSourceMeansAutoDetect() {
        let request = TranslationRequest(text: "hola", source: nil, target: .english)
        XCTAssertNil(request.source)
    }

    func testChunkCasesAreEquatable() {
        XCTAssertEqual(TranslationChunk.detected(.english), TranslationChunk.detected(.english))
        XCTAssertEqual(TranslationChunk.delta("a"), TranslationChunk.delta("a"))
        XCTAssertEqual(TranslationChunk.final("done"), TranslationChunk.final("done"))
        XCTAssertNotEqual(TranslationChunk.delta("a"), TranslationChunk.delta("b"))
        XCTAssertNotEqual(TranslationChunk.delta("x"), TranslationChunk.final("x"))
    }

    func testIdleFactoryProducesEmptyIdleResult() {
        let result = TranslationResult.idle("svc-1")
        XCTAssertEqual(result.serviceID, "svc-1")
        XCTAssertEqual(result.status, .idle)
        XCTAssertEqual(result.text, "")
        XCTAssertNil(result.detected)
        XCTAssertNil(result.errorMessage)
    }

    func testResultIdentifiableIDIsServiceID() {
        XCTAssertEqual(TranslationResult.idle("svc-2").id, "svc-2")
    }

    func testResultStatusCasesEquatable() {
        let statuses: [TranslationResult.Status] = [.idle, .loading, .streaming, .success, .failure]
        XCTAssertEqual(Set(statuses).count, statuses.count)
    }

    func testResultEquatable() {
        var a = TranslationResult.idle("svc")
        var b = TranslationResult.idle("svc")
        XCTAssertEqual(a, b)
        a.status = .success
        a.text = "hello"
        XCTAssertNotEqual(a, b)
        b.status = .success
        b.text = "hello"
        XCTAssertEqual(a, b)
    }

    func testDeferredFactoryProducesDeferredStatus() {
        let result = TranslationResult.deferred("svc")
        XCTAssertEqual(result.status, .deferred)
        XCTAssertEqual(result.serviceID, "svc")
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertNil(result.errorMessage)
    }
}

extension TranslationResult.Status: Hashable {}
