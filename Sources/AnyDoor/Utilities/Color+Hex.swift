import SwiftUI

extension Color {
    /// Parses a clipboard color literal into an sRGB `Color`, covering exactly
    /// the forms the capture classifier files under the Color facet: 3-, 4-, 6-
    /// and 8-digit hex, `rgb()`/`rgba()` and `hsl()`/`hsla()` in both the comma
    /// and the space/slash syntax, and AnyDoor's own SwiftUI form. Returns `nil`
    /// on malformed input so callers can fall back to a neutral swatch. This is
    /// the single literal→Color parser shared across the clipboard UI (card
    /// wall, history row swatch, and the history popover preview overlay).
    ///
    /// The grammar has to track the classifier's. Only 6-digit hex used to parse
    /// here, so every other literal it calls a Color — the CSS forms a user
    /// actually copies — rendered as a black swatch labelled "color".
    init?(colorLiteral text: String?) {
        guard let components = ClipboardColorLiteral.parse(text) else {
            return nil
        }
        self.init(
            .sRGB,
            red: components.red,
            green: components.green,
            blue: components.blue,
            opacity: components.alpha
        )
    }
}

/// The pure parser behind `Color(colorLiteral:)`, split out so it can be tested
/// against the classifier's table without building SwiftUI values.
enum ClipboardColorLiteral {
    struct Components: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
    }

    static func parse(_ text: String?) -> Components? {
        guard let raw = text?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !raw.isEmpty else {
            return nil
        }
        if raw.hasPrefix("#") || raw.allSatisfy(\.isHexDigit) {
            return hex(raw)
        }
        return function(raw)
    }

    private static func hex(_ value: String) -> Components? {
        var digits = Substring(value)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy(\.isHexDigit),
            let number = UInt64(digits, radix: 16)
        else {
            return nil
        }
        // The short forms repeat each nibble: #F00 is #FF0000.
        func channels(
            _ shifts: [Int],
            mask: UInt64,
            scale: Double
        ) -> [Double] {
            shifts.map { Double((number >> $0) & mask) / scale }
        }
        let values: [Double]
        switch digits.count {
        case 3:
            values = channels([8, 4, 0], mask: 0xF, scale: 15)
        case 4:
            values = channels([12, 8, 4, 0], mask: 0xF, scale: 15)
        case 6:
            values = channels([16, 8, 0], mask: 0xFF, scale: 255)
        case 8:
            values = channels([24, 16, 8, 0], mask: 0xFF, scale: 255)
        default:
            return nil
        }
        return Components(
            red: values[0],
            green: values[1],
            blue: values[2],
            alpha: values.count == 4 ? values[3] : 1
        )
    }

    private static func function(_ value: String) -> Components? {
        guard let open = value.firstIndex(of: "("), value.hasSuffix(")") else {
            return nil
        }
        let name = value[..<open].lowercased()
        var body = value[
            value.index(after: open)..<value.index(before: value.endIndex)
        ]
        if name == "color" {
            // AnyDoor's own SwiftUI form. `color(display-p3 …)` and the other
            // CSS extended functions share the name but not the labels, and the
            // classifier does not call those colors either.
            return swiftUIColor(body)
        }
        // The space syntax puts alpha behind a slash; the comma syntax makes it
        // a fourth argument.
        var alphaText: Substring?
        if let slash = body.firstIndex(of: "/") {
            alphaText = body[body.index(after: slash)...]
            body = body[..<slash]
        }
        var arguments = body.split { $0 == "," || $0.isWhitespace }
        if arguments.count == 4, alphaText == nil {
            alphaText = arguments.removeLast()
        }
        guard arguments.count == 3,
            let alpha = alpha(alphaText)
        else {
            return nil
        }

        switch name {
        case "rgb", "rgba":
            let channels = arguments.compactMap(byteOrPercentage)
            guard channels.count == 3 else { return nil }
            return Components(
                red: channels[0],
                green: channels[1],
                blue: channels[2],
                alpha: alpha
            )
        case "hsl", "hsla":
            guard let hue = degrees(arguments[0]),
                let saturation = percentage(arguments[1]),
                let lightness = percentage(arguments[2])
            else {
                return nil
            }
            return hsl(
                hue: hue,
                saturation: saturation,
                lightness: lightness,
                alpha: alpha
            )
        default:
            return nil
        }
    }

    /// `Color(red: 1.0, green: 0.0, blue: 0.0, opacity: 0.5)`. Its labels carry
    /// the argument order, so it splits on commas alone.
    private static func swiftUIColor(_ body: Substring) -> Components? {
        let labels = ["red:", "green:", "blue:", "opacity:"]
        let arguments = body.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard arguments.count == 3 || arguments.count == 4 else { return nil }
        let values = zip(arguments, labels).compactMap {
            argument, label -> Double? in
            guard argument.hasPrefix(label) else { return nil }
            return unit(
                argument.dropFirst(label.count)
                    .trimmingCharacters(in: .whitespaces)[...]
            )
        }
        guard values.count == arguments.count else { return nil }
        return Components(
            red: values[0],
            green: values[1],
            blue: values[2],
            alpha: values.count == 4 ? values[3] : 1
        )
    }

    private static func alpha(_ text: Substring?) -> Double? {
        guard let text else { return 1 }
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("%") {
            return Double(value.dropLast()).map { clamped($0 / 100) }
        }
        return unit(value[...])
    }

    private static func hsl(
        hue: Double,
        saturation: Double,
        lightness: Double,
        alpha: Double
    ) -> Components {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        var sector = hue.truncatingRemainder(dividingBy: 360) / 60
        if sector < 0 { sector += 6 }
        let secondary = chroma
            * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let base = lightness - chroma / 2
        let rgb: (Double, Double, Double)
        switch sector {
        case ..<1: rgb = (chroma, secondary, 0)
        case ..<2: rgb = (secondary, chroma, 0)
        case ..<3: rgb = (0, chroma, secondary)
        case ..<4: rgb = (0, secondary, chroma)
        case ..<5: rgb = (secondary, 0, chroma)
        default: rgb = (chroma, 0, secondary)
        }
        return Components(
            red: rgb.0 + base,
            green: rgb.1 + base,
            blue: rgb.2 + base,
            alpha: alpha
        )
    }

    private static func degrees(_ value: Substring) -> Double? {
        let lowered = value.lowercased()
        for (suffix, degreesPerUnit) in [
            ("deg", 1.0),
            ("grad", 0.9),
            ("rad", 180 / Double.pi),
            ("turn", 360.0),
        ] where lowered.hasSuffix(suffix) {
            guard let magnitude = Double(value.dropLast(suffix.count)) else {
                return nil
            }
            return magnitude * degreesPerUnit
        }
        return Double(value)
    }

    /// A channel is either a percentage of full scale or a 0...255 byte.
    private static func byteOrPercentage(_ value: Substring) -> Double? {
        if value.hasSuffix("%") {
            return Double(value.dropLast()).map { clamped($0 / 100) }
        }
        return Double(value).map { clamped($0 / 255) }
    }

    /// A saturation or lightness is a percentage, its sign optional.
    private static func percentage(_ value: Substring) -> Double? {
        let magnitude = value.hasSuffix("%") ? value.dropLast() : value
        return Double(magnitude).map { clamped($0 / 100) }
    }

    private static func unit(_ value: Substring) -> Double? {
        Double(value).map(clamped)
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
