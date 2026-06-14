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

    func testFrankfurterResponseDecodes() throws {
        // Captured from api.frankfurter.dev/v1/latest?base=USD — the `amount`
        // field must be ignored and base/date/rates mapped into the RateTable.
        let json = #"""
        {"amount":1.0,"base":"USD","date":"2026-06-12","rates":{"EUR":0.86453,"GBP":0.74613,"JPY":160.2}}
        """#
        let table = try FrankfurterRatesBackend.decode(Data(json.utf8))
        XCTAssertEqual(table.base, "USD")
        XCTAssertEqual(table.date, "2026-06-12")
        XCTAssertEqual(table.rate(for: "EUR"), 0.86453)
        XCTAssertEqual(table.rate(for: "USD"), 1)
    }

    func testFrankfurterEndpointIsV1() {
        // Guards against the /v2 path regression that returned 404.
        XCTAssertEqual(FrankfurterRatesBackend.endpoint, "https://api.frankfurter.dev/v1/latest")
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

    @MainActor
    func testForceRefreshFetchesEvenWhenFreshAndReportsSuccess() async {
        let backend = MockRatesBackend(table: Self.table)
        let service = CurrencyRatesService(backend: backend, defaults: isolatedDefaults(), base: "USD")

        await service.refreshIfStale(today: "2026-06-13")          // 1 fetch
        let forced = await service.forceRefresh()                   // forces a 2nd fetch despite being fresh
        XCTAssertTrue(forced)
        let calls = await backend.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(service.rateTable, Self.table)
    }

    @MainActor
    func testForceRefreshReportsFailureAndKeepsCache() async {
        let defaults = isolatedDefaults()
        let seed = CurrencyRatesService(backend: MockRatesBackend(table: Self.table), defaults: defaults, base: "USD")
        await seed.refreshIfStale(today: "2026-06-13")

        let failing = MockRatesBackend(table: Self.table, error: URLError(.notConnectedToInternet))
        let service = CurrencyRatesService(backend: failing, defaults: defaults, base: "USD")
        let forced = await service.forceRefresh()
        XCTAssertFalse(forced)
        XCTAssertEqual(service.rateTable, Self.table) // last good cache survives
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
