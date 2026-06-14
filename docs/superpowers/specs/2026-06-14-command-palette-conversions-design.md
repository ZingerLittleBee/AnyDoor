# Command Palette Conversions — Design

Date: 2026-06-14
Status: approved (decisions delegated to the implementer)

## Goal

Add inline **unit / time-zone / currency conversion** to the command palette,
following the same pure-core pattern already used by `Calculator` and `DevTools`.
Typing a conversion expression surfaces a "Conversion" section with the answer at
the top; pressing Return copies the value (content-free toast, matching dev tools).

Examples:

- `3 ft to m` → `0.9144 m`
- `100 kg in lb` → `220.4623 lb`
- `72 f to c` → `22.2222 °C`
- `1 gb to mib` → `953.6743 MiB`
- `3pm tokyo` → time in Tokyo (local 3pm interpreted)
- `9am london to tokyo` → 9am London shown in Tokyo
- `tokyo time` → current time in Tokyo
- `100 usd to eur` → `92.50 EUR` (subtitle: rate date)

## Non-goals

- Historical currency rates, multi-currency baskets, or live (per-keystroke) rate fetches.
- Natural-language dates ("next friday"), durations, or relative time math.
- A settings UI for conversions. Everything is auto-detected from the query.

## Architecture

Three independent **pure** converters, unified by one facade. Mirrors the
`DevTools.detect` / `Calculator.evaluate` shape: total, never throws, returns an
empty array on no-match. Only currency depends on injected data (a rate table);
the network/cache lives entirely outside the pure core.

```
Services/Conversion/
├── ConversionResult.swift     # value type: {kind, value, display, copyText, detail, symbol}
├── UnitConversion.swift       # pure: detect(_:) -> [ConversionResult]
├── TimeZoneConversion.swift   # pure: detect(_:now:localZone:) -> [ConversionResult]
├── CurrencyConversion.swift   # pure: detect(_:rates:) -> [ConversionResult]
├── RateTable.swift            # Codable {base, rates:[code:Double], date}
├── RatesBackend.swift         # protocol + FrankfurterRatesBackend (URLSession)
├── CurrencyRatesService.swift # @MainActor @Observable: UserDefaults cache + daily refresh
└── Conversions.swift          # facade: detect(query:rates:now:localZone:) merges the three
```

### `ConversionResult`

```swift
struct ConversionResult: Hashable, Sendable {
    enum Kind: String, Sendable { case unit, timeZone, currency }
    let kind: Kind
    let value: Double      // raw numeric answer (currency/unit); 0 for time-zone rows
    let display: String    // row title, e.g. "0.9144 m", "11:00 PM CST", "92.50 EUR"
    let copyText: String   // clipboard text — locale-independent ("." decimal, no grouping)
    let detail: String     // subtitle, e.g. "3 ft", "Tokyo · GMT+9", "as of 2026-06-13"
    let symbol: String     // SF Symbol for the row (ruler / clock / dollarsign.circle)
}
```

`display` is a presentation string formatted in the pure core using
`en_US_POSIX` + a `.decimal` formatter for numbers (no locale grouping) so tests
are deterministic. Time-zone strings are formatted with a fixed `h:mm a` pattern.

### Unit conversion

`detect` parses `"<number> <unit> (to|in) <unit>"` (case-insensitive). Source and
target must be in the **same category**; otherwise no row. Categories + a curated
alias table:

- **length**: m, km, cm, mm, µm/um, mi/mile, yd/yard, ft/foot/feet, in/inch, nmi
- **mass**: kg, g, mg, t/tonne, lb/lbs/pound, oz/ounce, st/stone
- **temperature** (affine): c/°c/celsius, f/°f/fahrenheit, k/kelvin
- **data**: bit, b/byte, kb, mb, gb, tb, pb (decimal ×1000); kib, mib, gib, tib (binary ×1024)
- **speed**: m/s · mps, km/h · kmh · kph, mph, kn · knot, ft/s · fps

Linear categories convert via a factor-to-base table (`value_target = value * factorSrc / factorDst`).
Temperature converts through Celsius with explicit affine formulas.

`copyText` is the numeric answer only; `display` appends the canonical unit symbol;
`detail` echoes the source side (`"3 ft"`).

### Time-zone conversion

`detect(_:now:localZone:)` is pure given an injected `now` and `localZone`.

Two crisply-defined forms (presence of `to` selects the second):

- **`<time?> <place>`** — `<time>` (optional; defaults to `now`) is in the **local**
  zone; the row shows that instant's wall-clock in `<place>`.
- **`<time?> <placeA> to <placeB>`** — `<time>` is in `<placeA>`'s zone; shown in `<placeB>`.

To avoid polluting app/command search, the single-place form requires either an
explicit time token **or** a trailing `time` keyword (`tokyo` alone → no row;
`tokyo time` / `3pm tokyo` → row).

- **Time tokens**: `3pm`, `3:30pm`, `3 pm`, `15:00`, `9am`, `noon`, `midnight`.
- **Places**: a curated lowercase alias → IANA-identifier map (~40 major cities +
  `utc`/`gmt`), plus raw IANA identifiers (`asia/tokyo`) accepted directly.
- **Output**: `display` = `"h:mm a"` + zone abbreviation, with a `(+1d)`/`(−1d)`
  marker when the target wall date differs from the source. `detail` = `"<src> → <dst>"`.
  `copyText` = the formatted time string.

### Currency conversion

`detect(_:rates:)` converts `"<amount> <codeA> (to|in) <codeB>"` (3-letter ISO
codes, case-insensitive) plus the symbol prefixes `$`→USD, `€`→EUR, `£`→GBP. When
`rates == nil` (never fetched) or a code is absent from the table, returns no row.

Conversion goes through the table base: `value_B = amount * rate[B] / rate[A]`
(with `rate[base] == 1`). `display` = `"<value> <CODE>"` (2-decimal), `copyText` =
the raw value, `detail` = a localized `"as of <date>"`.

`RateTable` is `Codable`; `rates` maps ISO code → units per 1 `base`.

**`RatesBackend`** isolates the network:

```swift
protocol RatesBackend: Sendable {
    func fetchLatest(base: String) async throws -> RateTable
}
struct FrankfurterRatesBackend: RatesBackend { /* GET api.frankfurter.dev/v2/latest?base= */ }
```

Frankfurter (ECB data) is key-free, unauthenticated, unmetered, ~30 major
currencies. Swapping to a broader provider later is a new backend behind the same
protocol — the pure converter is untouched.

**`CurrencyRatesService`** (`@MainActor @Observable`, like `CommandPaletteService`):

- `private(set) var rateTable: RateTable?`, seeded from a `UserDefaults` JSON cache on init.
- `refreshIfStale()` — when there is no table or `table.date` is older than today
  (in the local calendar), fetch via the backend and persist. One network call per
  day at most; offline falls back to the last cached table (with its `as of` date).
- Bootstrapped from `AppDelegate` on launch and re-poked when the palette opens.

The app is **non-sandboxed** (CGEvent-tap utility, no entitlements file), so
`URLSession` access needs no extra configuration.

## Palette wiring

- `PanelEntry.Source` gains `case conversion(ConversionResult)`; `id(for:)`,
  `localizedTitle()`, the `showsSubtitle`/`iconPath`/prewarm switches, and the
  `PanelSettingsView` command-palette-only branches all add it.
- `CommandPaletteState` gains a `conversionSection(matching:)` inserted near the
  Calculator section (final top→bottom: suggestions, calc, **conversion**, ports,
  hosts, dev tools). Currency rates are injected via a new
  `currencyRatesProvider: () -> RateTable? = { CurrencyRatesService.shared.rateTable }`
  init parameter (mirroring `hostProfilesProvider`) so state tests stay
  deterministic. Time-zone rows in the state path use the live `Date()`/`.current`;
  their correctness is covered by pure-module tests that inject `now`.
- `CommandPaletteWindowController.commit` adds a `.conversion` case: copy
  `copyText`, `noteSelfWrite`, content-free `toast.copiedToClipboard`. The palette
  refreshes currency rates on open (alongside the existing hosts reload).

## Section placement & collision safety

Conversion detection is high-signal: it requires a recognized unit/currency/place
**and** a connector or time token, so it does not steal ordinary command/app
search. Same reverse-priority insertion as the existing special sections (insert
at index 0; last-inserted ends on top).

## Testing

- `UnitConversionTests` — known vectors per category (ft→m, kg→lb, f↔c↔k, gb→mib,
  km/h→mph), same-category guard, no-connector/no-match cases.
- `TimeZoneConversionTests` — injected `now`/`localZone`; time parsing variants,
  single-place vs `to` two-place, day-offset marker, bare-city no-row guard.
- `CurrencyConversionTests` — fixed `RateTable`; cross conversion via base, symbol
  prefixes, `nil`-rates and unknown-code no-row, `as of` detail.
- `CurrencyRatesServiceTests` — Codable round-trip, staleness logic with a mock
  backend + isolated `UserDefaults`, offline keeps cache.
- `CommandPaletteTests` — conversion section surfaces for unit + (injected) currency
  queries; stable `id`; copy text; placeholder unaffected.
- `LocalizationCoverageTests` continues to enforce key ↔ catalog parity for the new
  keys (`commandPalette.section.conversion`, `conversion.currency.asOf`, etc.).

## Trade-offs / known limits

- Frankfurter covers ~30 currencies and updates once per business day; good for a
  utility, not for trading. Broader coverage is a future backend swap.
- Single-place time-zone form requires a time token or `time` keyword by design —
  bare city names won't produce a row (collision avoidance).
- `in` is a connector for unit/currency only; time-zone uses `to` exclusively to
  keep the source/target rule unambiguous.
