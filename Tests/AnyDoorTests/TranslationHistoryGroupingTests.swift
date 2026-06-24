import XCTest
@testable import AnyDoor

final class TranslationHistoryGroupingTests: XCTestCase {
    private func rec(run: String, service: String, text: String, fav: Bool = false, at: TimeInterval) -> TranslationRecord {
        TranslationRecord(
            sourceText: "good",
            translatedText: text,
            sourceLangCode: "en",
            targetLangCode: "zh-Hans",
            serviceID: service,
            serviceName: service.capitalized,
            isFavorite: fav,
            createdAt: Date(timeIntervalSinceReferenceDate: at),
            runID: run
        )
    }

    func testSameRunIDMergesIntoOneGroup() {
        let rows = [rec(run: "r1", service: "bing", text: "很好", at: 200),
                    rec(run: "r1", service: "google", text: "好的", at: 201)]
        let groups = groupByRun(rows)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].id, "r1")
        XCTAssertEqual(groups[0].records.count, 2)
    }

    func testEmptyRunIDRowsEachStandAlone() {
        let a = rec(run: "", service: "bing", text: "很好", at: 100)
        let b = rec(run: "", service: "google", text: "好的", at: 101)
        let groups = groupByRun([a, b])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].id, a.id)
        XCTAssertEqual(groups[1].id, b.id)
        XCTAssertEqual(groups[0].records.count, 1)
    }

    func testGroupOrderFollowsInputOrder() {
        // Caller passes newest-first; groups must come out in first-seen order.
        let rows = [rec(run: "rB", service: "bing", text: "b", at: 300),
                    rec(run: "rA", service: "bing", text: "a", at: 200)]
        let groups = groupByRun(rows)
        XCTAssertEqual(groups.map(\.id), ["rB", "rA"])
    }

    func testWithinGroupSortedByCreatedAtAscendingAndPrimaryIsEarliest() {
        let rows = [rec(run: "r1", service: "google", text: "late", at: 250),
                    rec(run: "r1", service: "bing", text: "early", at: 200)]
        let groups = groupByRun(rows)
        XCTAssertEqual(groups[0].records.map(\.translatedText), ["early", "late"])
        XCTAssertEqual(groups[0].primary.translatedText, "early")
    }

    func testIsFavoriteOnlyWhenAllRecordsFavorited() {
        let mixed = groupByRun([rec(run: "r1", service: "bing", text: "x", fav: true, at: 200),
                                rec(run: "r1", service: "google", text: "y", fav: false, at: 201)])
        XCTAssertFalse(mixed[0].isFavorite)
        let allFav = groupByRun([rec(run: "r2", service: "bing", text: "x", fav: true, at: 200),
                                 rec(run: "r2", service: "google", text: "y", fav: true, at: 201)])
        XCTAssertTrue(allFav[0].isFavorite)
    }

    func testCreatedAtIsGroupMax() {
        let groups = groupByRun([rec(run: "r1", service: "bing", text: "x", at: 200),
                                 rec(run: "r1", service: "google", text: "y", at: 260)])
        XCTAssertEqual(groups[0].createdAt, Date(timeIntervalSinceReferenceDate: 260))
    }
}
