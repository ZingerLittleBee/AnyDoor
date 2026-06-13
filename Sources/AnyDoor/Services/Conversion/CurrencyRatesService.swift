import Foundation
import Observation

/// Owns the cached currency rate table that powers `CurrencyConversion`. Mirrors
/// `CommandPaletteService`: a `@MainActor @Observable` singleton backed by
/// `UserDefaults`. Fetches at most once per calendar day; offline falls back to
/// the last cached table (carrying its own `date`).
@MainActor
@Observable
final class CurrencyRatesService {
    static let shared = CurrencyRatesService()

    private let backend: RatesBackend
    private let defaults: UserDefaults
    private let base: String
    private static let cacheKey = "currency.rateTable.v1"

    private var cached: CachedRates?
    private var inFlight = false

    /// The rate table available to the converter, or nil before the first fetch.
    var rateTable: RateTable? { cached?.table }

    init(backend: RatesBackend = FrankfurterRatesBackend(),
         defaults: UserDefaults = .standard,
         base: String = "USD") {
        self.backend = backend
        self.defaults = defaults
        self.base = base
        self.cached = Self.readCache(defaults)
    }

    /// Fetch fresh rates unless we already fetched today. On failure the existing
    /// cache is kept. `today` is injectable for deterministic tests.
    func refreshIfStale(today: String = CurrencyRatesService.todayString()) async {
        if cached?.fetchedOn == today { return }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        do {
            let table = try await backend.fetchLatest(base: base)
            let entry = CachedRates(table: table, fetchedOn: today)
            cached = entry
            writeCache(entry)
        } catch {
            // Offline / fetch failure: keep the last cached table (if any).
        }
    }

    static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - Cache

    private struct CachedRates: Codable, Sendable {
        let table: RateTable
        let fetchedOn: String
    }

    private static func readCache(_ defaults: UserDefaults) -> CachedRates? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedRates.self, from: data)
    }

    private func writeCache(_ entry: CachedRates) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }
}
