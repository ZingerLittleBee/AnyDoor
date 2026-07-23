import Foundation

/// A JSON-shaped value crossing the Swift↔JavaScript boundary: capability
/// arguments in, action results and stored values out.
///
/// Sendable and value-typed so it can safely leave the plugin's serial queue
/// (a `JSValue` cannot — it is bound to its context). The runtime decodes a
/// `JSValue` into a `ScriptValue` on the plugin queue before resuming any
/// `await`, and re-materializes a `ScriptValue` into a `JSValue` on the queue
/// when passing arguments in.
public enum ScriptValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    indirect case array([ScriptValue])
    indirect case object([String: ScriptValue])

    /// Convenience accessor for the common string case (row/detail decoding).
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    // MARK: - Foundation JSON bridge (used for key-value store persistence)

    /// A Foundation object graph suitable for `JSONSerialization`.
    public var foundationJSON: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .number(value): return value
        case let .string(value): return value
        case let .array(values): return values.map(\.foundationJSON)
        case let .object(fields): return fields.mapValues(\.foundationJSON)
        }
    }

    /// Reconstruct from a `JSONSerialization` object graph.
    public init(foundationJSON object: Any) {
        switch object {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // NSNumber conflates Bool and numeric; distinguish by the ObjC type.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let value as String:
            self = .string(value)
        case let array as [Any]:
            self = .array(array.map(ScriptValue.init(foundationJSON:)))
        case let dict as [String: Any]:
            self = .object(dict.mapValues(ScriptValue.init(foundationJSON:)))
        default:
            self = .null
        }
    }
}
