import Foundation
import PluginInterface

/// Decodes a plugin's `rows()` return value (a `ScriptValue`) into the host's
/// `PluginRowDescriptor` list. Pure and value-typed — it runs after the plugin
/// result has already crossed off the plugin queue.
enum ScriptRowDecoder {
    static func decode(_ value: ScriptValue) throws -> [PluginRowDescriptor] {
        guard case let .array(elements) = value else {
            throw ScriptPluginError.resultDecodingFailed("rows() must return an array")
        }
        return try elements.map(decodeRow)
    }

    private static func decodeRow(_ value: ScriptValue) throws -> PluginRowDescriptor {
        guard case let .object(fields) = value else {
            throw ScriptPluginError.resultDecodingFailed("each row must be an object")
        }
        guard let id = fields["id"]?.stringValue, !id.isEmpty else {
            throw ScriptPluginError.resultDecodingFailed("row is missing a string 'id'")
        }
        guard let title = fields["title"]?.stringValue else {
            throw ScriptPluginError.resultDecodingFailed("row '\(id)' is missing a string 'title'")
        }

        let commit: PluginRowDescriptor.CommitSemantics
        switch fields["commit"]?.stringValue {
        case "closeThenAct": commit = .closeThenAct
        default: commit = .stayOpen
        }

        return PluginRowDescriptor(
            id: id,
            title: title,
            subtitle: fields["subtitle"]?.stringValue,
            symbol: fields["symbol"]?.stringValue ?? "puzzlepiece.extension",
            actionLabel: fields["actionLabel"]?.stringValue,
            isChecked: {
                if case let .bool(checked) = fields["isChecked"] { return checked }
                return false
            }(),
            commit: commit
        )
    }
}
