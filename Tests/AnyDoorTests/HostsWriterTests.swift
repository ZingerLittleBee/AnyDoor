import XCTest
@testable import AnyDoor

final class HostsWriterTests: XCTestCase {
    func test_mockRecordsLastWrite() async throws {
        let mock = MockHostsWriter()
        try await mock.write("hello")
        XCTAssertEqual(mock.lastWritten, "hello")
        XCTAssertEqual(mock.writeCount, 1)
    }

    func test_mockThrowsWhenConfigured() async {
        let mock = MockHostsWriter()
        mock.errorToThrow = HostsWriterError.writeFailed("boom")
        do {
            try await mock.write("x")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(mock.writeCount, 0)
        }
    }
}
