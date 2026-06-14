import Foundation

/// Fetches the latest exchange rates for a base currency. Isolated behind a
/// protocol so the network source is swappable and mockable in tests.
protocol RatesBackend: Sendable {
    func fetchLatest(base: String) async throws -> RateTable
}

/// Frankfurter (ECB data): key-free, unauthenticated, ~30 major currencies,
/// updated once per business day. Endpoint: `api.frankfurter.dev/v1/latest`.
struct FrankfurterRatesBackend: RatesBackend {
    /// The live "latest rates" endpoint. `base` is supplied as a query item.
    static let endpoint = "https://api.frankfurter.dev/v1/latest"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLatest(base: String) async throws -> RateTable {
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [URLQueryItem(name: "base", value: base)]
        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try Self.decode(data)
    }

    /// Decodes a Frankfurter `latest` response into a `RateTable`. Exposed so the
    /// wire-format contract is unit-testable without a live network call.
    static func decode(_ data: Data) throws -> RateTable {
        let dto = try JSONDecoder().decode(FrankfurterLatest.self, from: data)
        return RateTable(base: dto.base, rates: dto.rates, date: dto.date)
    }

    /// Wire shape: `{ "amount": 1.0, "base": "USD", "date": "2026-06-12", "rates": {…} }`.
    /// `amount` is ignored (we always request the default amount of 1).
    private struct FrankfurterLatest: Decodable {
        let base: String
        let date: String
        let rates: [String: Double]
    }
}
