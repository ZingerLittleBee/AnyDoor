import XCTest
@testable import AnyDoor

final class SecureInputOwnerTests: XCTestCase {
    func testUsesOnlyCurrentUsersConsoleSession() {
        let sessions: [[String: Any]] = [
            ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 502,
             "kCGSSessionSecureInputPID": 100],
            ["kCGSSessionOnConsoleKey": false, "kCGSSessionUserIDKey": 501,
             "kCGSSessionSecureInputPID": 200],
            ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501,
             "kCGSSessionSecureInputPID": 300]
        ]
        XCTAssertEqual(SecureInputOwner.processID(in: sessions, userID: 501), 300)
    }

    func testMissingOwnerDoesNotFallBackToAnotherUsersProcess() {
        let sessions: [[String: Any]] = [
            ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501],
            ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 502,
             "kCGSSessionSecureInputPID": 100]
        ]
        XCTAssertNil(SecureInputOwner.processID(in: sessions, userID: 501))
    }

    func testRejectsInvalidProcessIdentifiers() {
        for invalidPID: Any in [0, -1, Int64(Int32.max) + 1, "734"] {
            let sessions: [[String: Any]] = [
                ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserIDKey": 501,
                 "kCGSSessionSecureInputPID": invalidPID]
            ]
            XCTAssertNil(SecureInputOwner.processID(in: sessions, userID: 501))
        }
    }
}
