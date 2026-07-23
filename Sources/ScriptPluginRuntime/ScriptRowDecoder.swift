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

        let commit = try decodeCommit(fields, rowID: id)

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
            badge: fields["badge"]?.stringValue,
            commit: commit
        )
    }

    /// Decode a row's commit semantics. The forward form is an `action`
    /// discriminated union (`{ type: "detail" | "list" | "openURL" | "copy" |
    /// "argument" | "run", ... }`); when absent, the legacy `commit` string is
    /// honored so existing packages keep working. The host-only `noAction`/`runArgument`
    /// cases are never authored by a plugin, so they are not decodable here.
    private static func decodeCommit(
        _ fields: [String: ScriptValue],
        rowID: String
    ) throws -> PluginRowDescriptor.CommitSemantics {
        guard case let .object(action)? = fields["action"] else {
            // Legacy form: a bare `commit` string.
            switch fields["commit"]?.stringValue {
            case "closeThenAct": return .closeThenAct
            default: return .stayOpen
            }
        }
        let type = action["type"]?.stringValue ?? "run"
        switch type {
        case "detail":
            return .pushDetail
        case "argument":
            return .enterArgument
        case "list":
            guard let listID = action["id"]?.stringValue, !listID.isEmpty else {
                throw ScriptPluginError.resultDecodingFailed(
                    "row '\(rowID)' list action is missing a string 'id'")
            }
            return .pushList(listID)
        case "openURL":
            guard let url = action["url"]?.stringValue, !url.isEmpty else {
                throw ScriptPluginError.resultDecodingFailed(
                    "row '\(rowID)' openURL action is missing a string 'url'")
            }
            return .openURL(url)
        case "copy":
            guard let text = action["text"]?.stringValue else {
                throw ScriptPluginError.resultDecodingFailed(
                    "row '\(rowID)' copy action is missing a string 'text'")
            }
            return .copy(text)
        case "run":
            // A function invocation closes the palette by default; `close: false`
            // keeps it open (e.g. a toggle-style action that refreshes the list).
            if case .bool(false) = action["close"] { return .stayOpen }
            return .closeThenAct
        default:
            throw ScriptPluginError.resultDecodingFailed(
                "row '\(rowID)' has an unknown action type '\(type)'")
        }
    }
}
