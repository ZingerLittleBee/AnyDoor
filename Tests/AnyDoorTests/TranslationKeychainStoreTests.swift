import XCTest
@testable import AnyDoor

final class TranslationKeychainStoreTests: XCTestCase {
    private var serviceName = ""

    override func setUp() {
        super.setUp()
        // Unique throwaway service so we never collide with the real app keychain.
        serviceName = "dev.bybee.AnyDoor.translation.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        // Best-effort cleanup of anything a test left behind.
        let store = TranslationKeychainStore(service: serviceName)
        for id in ["a", "b", "missing", "roundtrip"] {
            store.deleteAPIKey(for: id)
        }
        super.tearDown()
    }

    func testReadMissingKeyReturnsNil() {
        let store = TranslationKeychainStore(service: serviceName)
        XCTAssertNil(store.apiKey(for: "missing"))
    }

    func testRoundTrip() {
        let store = TranslationKeychainStore(service: serviceName)
        store.setAPIKey("sk-secret-123", for: "roundtrip")
        XCTAssertEqual(store.apiKey(for: "roundtrip"), "sk-secret-123")
    }

    func testSetOverwritesExistingValue() {
        let store = TranslationKeychainStore(service: serviceName)
        store.setAPIKey("first", for: "a")
        store.setAPIKey("second", for: "a")
        XCTAssertEqual(store.apiKey(for: "a"), "second")
    }

    func testDeleteRemovesValue() {
        let store = TranslationKeychainStore(service: serviceName)
        store.setAPIKey("to-delete", for: "b")
        XCTAssertEqual(store.apiKey(for: "b"), "to-delete")
        store.deleteAPIKey(for: "b")
        XCTAssertNil(store.apiKey(for: "b"))
    }

    func testKeysAreScopedByAccount() {
        let store = TranslationKeychainStore(service: serviceName)
        store.setAPIKey("alpha", for: "a")
        store.setAPIKey("beta", for: "b")
        XCTAssertEqual(store.apiKey(for: "a"), "alpha")
        XCTAssertEqual(store.apiKey(for: "b"), "beta")
    }

    func testServiceIsolation() {
        let storeA = TranslationKeychainStore(service: serviceName)
        let storeB = TranslationKeychainStore(service: serviceName + ".other")
        storeA.setAPIKey("only-in-a", for: "a")
        XCTAssertNil(storeB.apiKey(for: "a"))
        storeB.deleteAPIKey(for: "a") // nothing to clean, but keep symmetric
    }
}
