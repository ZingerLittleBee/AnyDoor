import Foundation

/// One inline conversion surfaced by the command palette (unit / time-zone /
/// currency). Pure data, mirroring `DevToolResult` / `CalcResult`: produced by
/// the pure converters, rendered by the palette, and copied on Return.
struct ConversionResult: Hashable, Sendable {
    enum Kind: String, Sendable {
        case unit
        case timeZone
        case currency
    }

    /// Which converter produced the row — drives the id namespace and row symbol.
    let kind: Kind
    /// Raw numeric answer (unit / currency). `0` for time-zone rows, which carry
    /// their answer only as a formatted string.
    let value: Double
    /// Row title, e.g. `"0.9144 m"`, `"11:00 PM CST"`, `"92.50 EUR"`.
    let display: String
    /// Clipboard text — locale-independent (`"."` decimal, no grouping).
    let copyText: String
    /// Subtitle, e.g. `"3 ft"`, `"Tokyo · GMT+9"`, `"as of 2026-06-13"`.
    let detail: String
    /// SF Symbol for the row.
    let symbol: String
}
