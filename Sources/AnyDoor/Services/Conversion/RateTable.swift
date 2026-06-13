import Foundation

/// A snapshot of exchange rates relative to a single base currency. `rates` maps
/// an ISO 4217 code to "units of that currency per 1 unit of `base`". The base
/// currency itself may be absent from `rates` (treated as 1.0). `date` is the
/// source's reference date (e.g. ECB's daily date), formatted `yyyy-MM-dd`.
struct RateTable: Codable, Hashable, Sendable {
    let base: String
    let rates: [String: Double]
    let date: String

    /// Units of `code` per 1 unit of `base`. Returns 1 for the base itself, nil
    /// when the code is not in the table.
    func rate(for code: String) -> Double? {
        if code == base { return 1 }
        return rates[code]
    }
}
