import Foundation

/// The whitelisted constants and functions the evaluator recognizes. Adding a
/// function is a single-entry edit here. Trig is radian-based.
enum CalcFunctions {
    static let constants: [String: Double] = [
        "pi": Double.pi,
        "e": M_E,
    ]

    /// Apply a named function to its argument list, or throw on unknown
    /// name / wrong arity.
    static func apply(_ name: String, _ args: [Double]) throws -> Double {
        if let fn = unary[name] {
            guard args.count == 1 else { throw CalcError.wrongArity(name) }
            return fn(args[0])
        }
        if let fn = binary[name] {
            guard args.count == 2 else { throw CalcError.wrongArity(name) }
            return fn(args[0], args[1])
        }
        throw CalcError.unknownIdentifier(name)
    }

    private static let unary: [String: @Sendable (Double) -> Double] = [
        "sqrt": { Foundation.sqrt($0) },
        "cbrt": { Foundation.cbrt($0) },
        "abs":  { Swift.abs($0) },
        "ln":   { Foundation.log($0) },        // natural log (base e)
        "log":  { Foundation.log10($0) },      // base-10 log
        "log10": { Foundation.log10($0) },     // alias of log
        "log2": { Foundation.log2($0) },
        "exp":  { Foundation.exp($0) },
        "sin":  { Foundation.sin($0) },
        "cos":  { Foundation.cos($0) },
        "tan":  { Foundation.tan($0) },
        "asin": { Foundation.asin($0) },
        "acos": { Foundation.acos($0) },
        "atan": { Foundation.atan($0) },
        "sinh": { Foundation.sinh($0) },
        "cosh": { Foundation.cosh($0) },
        "tanh": { Foundation.tanh($0) },
        "floor": { Foundation.floor($0) },
        "ceil": { Foundation.ceil($0) },
        "round": { $0.rounded() },
    ]

    private static let binary: [String: @Sendable (Double, Double) -> Double] = [
        "pow": { Foundation.pow($0, $1) },
        "min": { Swift.min($0, $1) },
        "max": { Swift.max($0, $1) },
    ]
}
