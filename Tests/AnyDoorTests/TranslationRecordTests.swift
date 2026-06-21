import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class TranslationRecordTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: TranslationRecord.self, configurations: config)
    }

    func testInitAssignsUniqueIDAndDefaults() {
        let a = TranslationRecord(
            sourceText: "hello",
            translatedText: "你好",
            sourceLangCode: "en",
            targetLangCode: "zh-Hans",
            serviceID: "google",
            serviceName: "Google"
        )
        let b = TranslationRecord(
            sourceText: "hello",
            translatedText: "你好",
            sourceLangCode: "en",
            targetLangCode: "zh-Hans",
            serviceID: "google",
            serviceName: "Google"
        )
        XCTAssertFalse(a.id.isEmpty)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertFalse(a.isFavorite)
        XCTAssertEqual(a.sourceText, "hello")
        XCTAssertEqual(a.translatedText, "你好")
        XCTAssertEqual(a.sourceLangCode, "en")
        XCTAssertEqual(a.targetLangCode, "zh-Hans")
        XCTAssertEqual(a.serviceID, "google")
        XCTAssertEqual(a.serviceName, "Google")
    }

    func testRecordPersistsAndRefetches() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let created = Date(timeIntervalSinceReferenceDate: 1_000)
        let record = TranslationRecord(
            sourceText: "cat",
            translatedText: "猫",
            sourceLangCode: "en",
            targetLangCode: "zh-Hans",
            serviceID: "bing",
            serviceName: "Bing",
            isFavorite: true,
            createdAt: created
        )
        context.insert(record)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<TranslationRecord>())
        let stored = try XCTUnwrap(rows.first)
        XCTAssertEqual(stored.translatedText, "猫")
        XCTAssertTrue(stored.isFavorite)
        XCTAssertEqual(stored.createdAt, created)
    }
}
