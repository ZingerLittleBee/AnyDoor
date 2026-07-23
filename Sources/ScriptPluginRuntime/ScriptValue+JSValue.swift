import Foundation
import JavaScriptCore

extension ScriptValue {
    /// Decode a `JSValue` (bound to its context, so this must run on the plugin
    /// queue) into a value-typed `ScriptValue` that can safely cross back to the
    /// awaiting caller.
    init(jsValue: JSValue) {
        if jsValue.isUndefined || jsValue.isNull {
            self = .null
        } else if jsValue.isBoolean {
            self = .bool(jsValue.toBool())
        } else if jsValue.isNumber {
            self = .number(jsValue.toDouble())
        } else if jsValue.isString {
            self = .string(jsValue.toString() ?? "")
        } else if let object = jsValue.toObject() {
            // Arrays, dictionaries, and boxed scalars bridge to Foundation.
            self = ScriptValue(foundationJSON: object)
        } else {
            self = .null
        }
    }

    /// Materialize a `JSValue` in `context` (must run on the plugin queue).
    /// Built explicitly rather than through `JSValue(object:)` so a `.bool`
    /// never collapses into a `0`/`1` number across the NSNumber bridge.
    func makeJSValue(in context: JSContext) -> JSValue {
        let fallback = JSValue(undefinedIn: context) ?? JSValue()
        switch self {
        case .null:
            return JSValue(nullIn: context) ?? fallback
        case let .bool(value):
            return JSValue(bool: value, in: context) ?? fallback
        case let .number(value):
            return JSValue(double: value, in: context) ?? fallback
        case let .string(value):
            return JSValue(object: value, in: context) ?? fallback
        case let .array(values):
            guard let array = JSValue(newArrayIn: context) else { return fallback }
            for (index, value) in values.enumerated() {
                array.setObject(value.makeJSValue(in: context), atIndexedSubscript: index)
            }
            return array
        case let .object(fields):
            guard let object = JSValue(newObjectIn: context) else { return fallback }
            for (key, value) in fields {
                object.setObject(value.makeJSValue(in: context), forKeyedSubscript: key as NSString)
            }
            return object
        }
    }
}
