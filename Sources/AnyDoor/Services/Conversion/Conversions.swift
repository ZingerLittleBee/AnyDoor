import Foundation

/// Facade merging the three pure converters for the command palette. Mirrors
/// `DevTools.detect` / `Calculator.evaluate`: total, never throws, returns an
/// empty array when nothing applies. A query normally matches at most one
/// converter, so the rows are simply concatenated in a stable order.
enum Conversions {
    static func detect(
        query: String,
        rates: RateTable?,
        now: Date,
        localZone: TimeZone
    ) -> [ConversionResult] {
        var rows: [ConversionResult] = []
        rows += UnitConversion.detect(query)
        rows += CurrencyConversion.detect(query, rates: rates)
        rows += TimeZoneConversion.detect(query, now: now, localZone: localZone)
        return rows
    }
}
