import Foundation

/// A portable UserDefaults preference a Native Plugin contributes to config
/// backup. Declared statically by the plugin (like `modelSchemaTypes`) and
/// aggregated by the host's sync whitelist, so the plugin stays the one owner
/// of its preference keys and Core never hardcodes them.
public struct PluginSyncedDefault: Sendable, Equatable {
    /// The value shape backup serialization reads and writes for this key.
    public enum ValueType: Sendable, Equatable {
        case bool
        case int
        case string
        case stringArray
    }

    public let key: String
    public let type: ValueType

    public init(key: String, type: ValueType) {
        self.key = key
        self.type = type
    }
}
