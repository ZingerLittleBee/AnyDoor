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
    /// The day we last *attempted* a fetch (success or failure). Backs failed/
    /// offline fetches off to one try per day, so reopening the palette while
    /// offline doesn't spawn a fresh ~60s request each time.
    private var lastAttemptDay: String?

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
        if lastAttemptDay == today { return }
        guard !inFlight else { return }
        inFlight = true
        lastAttemptDay = today
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

    /// Force a fetch regardless of staleness (the "更新汇率" footer button).
    /// Returns whether fresh rates were fetched; on failure the last good cache is
    /// kept. Still honors the in-flight guard so a double-tap can't stack requests.
    @discardableResult
    func forceRefresh() async -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        let today = Self.todayString()
        lastAttemptDay = today
        defer { inFlight = false }
        do {
            let table = try await backend.fetchLatest(base: base)
            let entry = CachedRates(table: table, fetchedOn: today)
            cached = entry
            writeCache(entry)
            return true
        } catch {
            return false
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
