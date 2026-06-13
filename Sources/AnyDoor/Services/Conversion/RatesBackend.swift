import Foundation

/// Fetches the latest exchange rates for a base currency. Isolated behind a
/// protocol so the network source is swappable and mockable in tests.
protocol RatesBackend: Sendable {
    func fetchLatest(base: String) async throws -> RateTable
}

/// Frankfurter (ECB data): key-free, unauthenticated, ~30 major currencies,
/// updated once per business day. Endpoint: `api.frankfurter.dev/v2/latest`.
struct FrankfurterRatesBackend: RatesBackend {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLatest(base: String) async throws -> RateTable {
        var components = URLComponents(string: "https://api.frankfurter.dev/v2/latest")!
        components.queryItems = [URLQueryItem(name: "base", value: base)]
        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let dto = try JSONDecoder().decode(FrankfurterLatest.self, from: data)
        return RateTable(base: dto.base, rates: dto.rates, date: dto.date)
    }

    private struct FrankfurterLatest: Decodable {
        let base: String
        let date: String
        let rates: [String: Double]
    }
}
