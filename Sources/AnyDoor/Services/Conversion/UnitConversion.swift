import Foundation

/// Pure, total unit converter for the command palette. Parses
/// `"<number> <unit> (to|in) <unit>"` and converts when both units share a
/// category. Returns an empty array on any non-match. Never throws.
enum UnitConversion {
    static func detect(_ query: String) -> [ConversionResult] {
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return [] }

        // " to " wins over " in " so that "in" (inch) survives as a unit when the
        // user also types a " to " connector (e.g. "5 in to cm").
        guard let (lhs, rhs) = split(lowered) else { return [] }

        guard let (amount, sourceToken) = leadingNumber(lhs) else { return [] }
        let targetToken = rhs.trimmingCharacters(in: .whitespaces)
        guard let source = units[sourceToken], let target = units[targetToken],
              source.category == target.category else { return [] }

        let value = convert(amount, from: source, to: target)
        let number = Self.format(value)
        return [ConversionResult(
            kind: .unit,
            value: value,
            display: "\(number) \(target.symbol)",
            copyText: number,
            detail: "\(Self.format(amount)) \(source.symbol)",
            symbol: "ruler"
        )]
    }

    // MARK: - Parsing

    /// Splits on a connector: " to " (preferred), " in ", or "=" (with or without
    /// surrounding spaces). " to " wins so "in" (inch) survives as a unit.
    private static func split(_ s: String) -> (String, String)? {
        for separator in [" to ", " in ", "="] {
            if let range = s.range(of: separator) {
                return (String(s[..<range.lowerBound]), String(s[range.upperBound...]))
            }
        }
        return nil
    }

    /// Extracts a leading signed decimal number and returns it plus the trimmed
    /// remainder (the source unit token), or nil when there is no number.
    private static func leadingNumber(_ s: String) -> (Double, String)? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        var numberChars = ""
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let c = trimmed[index]
            let isSign = c == "-" && numberChars.isEmpty
            if c.isNumber || c == "." || isSign {
                numberChars.append(c)
                index = trimmed.index(after: index)
            } else {
                break
            }
        }
        guard let amount = Double(numberChars) else { return nil }
        let unit = String(trimmed[index...]).trimmingCharacters(in: .whitespaces)
        guard !unit.isEmpty else { return nil }
        return (amount, unit)
    }

    // MARK: - Conversion

    private static func convert(_ value: Double, from source: Unit, to target: Unit) -> Double {
        if let sourceTemp = source.temp, let targetTemp = target.temp {
            return targetTemp.fromCelsius(sourceTemp.toCelsius(value))
        }
        // Linear: value in base units = value * toBase; then divide by target's.
        return value * source.toBase / target.toBase
    }

    // MARK: - Formatting

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Up to 4 fractional digits, trailing zeros trimmed, no grouping, "." decimal.
    static func format(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = posix
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 4
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    // MARK: - Unit model

    private enum Category: Sendable { case length, mass, temperature, data, speed }

    /// Temperature is affine, so it can't share the linear factor path. Each unit
    /// tags which temperature scale it is and converts through Celsius.
    private enum Temp: Sendable {
        case celsius, fahrenheit, kelvin

        func toCelsius(_ v: Double) -> Double {
            switch self {
            case .celsius: return v
            case .fahrenheit: return (v - 32) * 5 / 9
            case .kelvin: return v - 273.15
            }
        }

        func fromCelsius(_ c: Double) -> Double {
            switch self {
            case .celsius: return c
            case .fahrenheit: return c * 9 / 5 + 32
            case .kelvin: return c + 273.15
            }
        }
    }

    private struct Unit: Sendable {
        let category: Category
        let symbol: String
        /// Factor to the category's base unit (linear categories only).
        let toBase: Double
        /// Non-nil only for temperature units.
        var temp: Temp? = nil
    }

    /// Lowercased alias → unit. Base units: length=metre, mass=gram, data=byte,
    /// speed=metre/second. Temperature is affine and ignores `toBase`.
    private static let units: [String: Unit] = {
        var map: [String: Unit] = [:]
        func add(_ aliases: [String], _ unit: Unit) {
            for alias in aliases { map[alias] = unit }
        }

        // Length (base: metre)
        add(["m", "meter", "meters", "metre", "metres"], Unit(category: .length, symbol: "m", toBase: 1))
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], Unit(category: .length, symbol: "km", toBase: 1000))
        add(["cm", "centimeter", "centimeters"], Unit(category: .length, symbol: "cm", toBase: 0.01))
        add(["mm", "millimeter", "millimeters"], Unit(category: .length, symbol: "mm", toBase: 0.001))
        add(["um", "µm", "micron", "microns"], Unit(category: .length, symbol: "µm", toBase: 1e-6))
        add(["mi", "mile", "miles"], Unit(category: .length, symbol: "mi", toBase: 1609.344))
        add(["yd", "yard", "yards"], Unit(category: .length, symbol: "yd", toBase: 0.9144))
        add(["ft", "foot", "feet"], Unit(category: .length, symbol: "ft", toBase: 0.3048))
        add(["in", "inch", "inches"], Unit(category: .length, symbol: "in", toBase: 0.0254))
        add(["nmi", "nauticalmile", "nauticalmiles"], Unit(category: .length, symbol: "nmi", toBase: 1852))

        // Mass (base: gram)
        add(["kg", "kilogram", "kilograms"], Unit(category: .mass, symbol: "kg", toBase: 1000))
        add(["g", "gram", "grams"], Unit(category: .mass, symbol: "g", toBase: 1))
        add(["mg", "milligram", "milligrams"], Unit(category: .mass, symbol: "mg", toBase: 0.001))
        add(["t", "tonne", "tonnes", "metricton"], Unit(category: .mass, symbol: "t", toBase: 1_000_000))
        add(["lb", "lbs", "pound", "pounds"], Unit(category: .mass, symbol: "lb", toBase: 453.59237))
        add(["oz", "ounce", "ounces"], Unit(category: .mass, symbol: "oz", toBase: 28.349523125))
        add(["st", "stone", "stones"], Unit(category: .mass, symbol: "st", toBase: 6350.29318))

        // Temperature (affine)
        add(["c", "°c", "celsius", "centigrade"], Unit(category: .temperature, symbol: "°C", toBase: 1, temp: .celsius))
        add(["f", "°f", "fahrenheit"], Unit(category: .temperature, symbol: "°F", toBase: 1, temp: .fahrenheit))
        add(["k", "kelvin"], Unit(category: .temperature, symbol: "K", toBase: 1, temp: .kelvin))

        // Data (base: byte). Decimal ×1000; binary ×1024.
        add(["bit", "bits"], Unit(category: .data, symbol: "bit", toBase: 0.125))
        add(["b", "byte", "bytes"], Unit(category: .data, symbol: "B", toBase: 1))
        add(["kb", "kilobyte", "kilobytes"], Unit(category: .data, symbol: "KB", toBase: 1000))
        add(["mb", "megabyte", "megabytes"], Unit(category: .data, symbol: "MB", toBase: 1_000_000))
        add(["gb", "gigabyte", "gigabytes"], Unit(category: .data, symbol: "GB", toBase: 1_000_000_000))
        add(["tb", "terabyte", "terabytes"], Unit(category: .data, symbol: "TB", toBase: 1_000_000_000_000))
        add(["pb", "petabyte", "petabytes"], Unit(category: .data, symbol: "PB", toBase: 1_000_000_000_000_000))
        add(["kib", "kibibyte", "kibibytes"], Unit(category: .data, symbol: "KiB", toBase: 1024))
        add(["mib", "mebibyte", "mebibytes"], Unit(category: .data, symbol: "MiB", toBase: 1_048_576))
        add(["gib", "gibibyte", "gibibytes"], Unit(category: .data, symbol: "GiB", toBase: 1_073_741_824))
        add(["tib", "tebibyte", "tebibytes"], Unit(category: .data, symbol: "TiB", toBase: 1_099_511_627_776))

        // Speed (base: metre/second)
        add(["m/s", "mps", "meterspersecond"], Unit(category: .speed, symbol: "m/s", toBase: 1))
        add(["km/h", "kmh", "kph", "kilometersperhour"], Unit(category: .speed, symbol: "km/h", toBase: 1000.0 / 3600.0))
        add(["mph", "milesperhour"], Unit(category: .speed, symbol: "mph", toBase: 1609.344 / 3600.0))
        add(["kn", "knot", "knots"], Unit(category: .speed, symbol: "kn", toBase: 1852.0 / 3600.0))
        add(["ft/s", "fps", "feetpersecond"], Unit(category: .speed, symbol: "ft/s", toBase: 0.3048))

        return map
    }()
}
