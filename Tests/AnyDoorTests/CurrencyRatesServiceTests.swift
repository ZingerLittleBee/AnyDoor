import XCTest
@testable import AnyDoor

final class CurrencyRatesServiceTests: XCTestCase {
    private static let table = RateTable(
        base: "USD",
        rates: ["EUR": 0.925, "GBP": 0.79],
        date: "2026-06-13"
    )

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CurrencyRatesServiceTests-\(UUID().uuidString)")!
    }

    func testRateTableCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.table)
        let decoded = try JSONDecoder().decode(RateTable.self, from: data)
        XCTAssertEqual(decoded, Self.table)
    }

    @MainActor
    func testFetchesAndCachesWhenEmpty() async {
        let backend = MockRatesBackend(table: Self.table)
        let service = CurrencyRatesService(backend: backend, defaults: isolatedDefaults(), base: "USD")
        XCTAssertNil(service.rateTable)

        await service.refreshIfStale(today: "2026-06-13")

        XCTAssertEqual(service.rateTable, Self.table)
        let calls = await backend.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testSkipsFetchWhenAlreadyFetchedToday() async {
        let backend = MockRatesBackend(table: Self.table)
        let service = CurrencyRatesService(backend: backend, defaults: isolatedDefaults(), base: "USD")

        await service.refreshIfStale(today: "2026-06-13")
        await service.refreshIfStale(today: "2026-06-13")

        let calls = await backend.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testRefetchesOnNewDay() async {
        let backend = MockRatesBackend(table: Self.table)
        let service = CurrencyRatesService(backend: backend, defaults: isolatedDefaults(), base: "USD")

        await service.refreshIfStale(today: "2026-06-13")
        await service.refreshIfStale(today: "2026-06-14")

        let calls = await backend.calls
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testReadsCacheOnInit() async {
        let defaults = isolatedDefaults()
        let first = CurrencyRatesService(backend: MockRatesBackend(table: Self.table), defaults: defaults, base: "USD")
        await first.refreshIfStale(today: "2026-06-13")

        // A fresh instance over the same defaults sees the cached table without fetching.
        let backend = MockRatesBackend(table: Self.table)
        let second = CurrencyRatesService(backend: backend, defaults: defaults, base: "USD")
        XCTAssertEqual(second.rateTable, Self.table)
        let calls = await backend.calls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testOfflineKeepsCachedTable() async {
        let defaults = isolatedDefaults()
        let seed = CurrencyRatesService(backend: MockRatesBackend(table: Self.table), defaults: defaults, base: "USD")
        await seed.refreshIfStale(today: "2026-06-13")

        // New day, but the backend now fails — the cached table must survive.
        let failing = MockRatesBackend(table: Self.table, error: URLError(.notConnectedToInternet))
        let service = CurrencyRatesService(backend: failing, defaults: defaults, base: "USD")
        await service.refreshIfStale(today: "2026-06-14")

        XCTAssertEqual(service.rateTable, Self.table)
    }

    @MainActor
    func testFailedFetchBacksOffSameDay() async {
        let backend = MockRatesBackend(table: Self.table, error: URLError(.notConnectedToInternet))
        let service = CurrencyRatesService(backend: backend, defaults: isolatedDefaults(), base: "USD")

        await service.refreshIfStale(today: "2026-06-13")
        await service.refreshIfStale(today: "2026-06-13")
        let sameDay = await backend.calls
        XCTAssertEqual(sameDay, 1, "a same-day retry after a failure must not refetch")

        await service.refreshIfStale(today: "2026-06-14")
        let nextDay = await backend.calls
        XCTAssertEqual(nextDay, 2, "a new day should retry")
    }

    private actor MockRatesBackend: RatesBackend {
        private let table: RateTable
        private let error: Error?
        private(set) var calls = 0

        init(table: RateTable, error: Error? = nil) {
            self.table = table
            self.error = error
        }

        func fetchLatest(base: String) async throws -> RateTable {
            calls += 1
            if let error { throw error }
            return table
        }
    }
}
