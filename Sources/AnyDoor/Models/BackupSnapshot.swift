import Foundation

/// Type-tagged scalar for whitelisted UserDefaults values so the JSON stays
/// strongly typed and decodes back into the correct Swift type.
enum SettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)

    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "bool":   self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int":    self = .int(try c.decode(Int.self, forKey: .value))
        case "string": self = .string(try c.decode(String.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown SettingValue type \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bool(let v):   try c.encode("bool", forKey: .type);   try c.encode(v, forKey: .value)
        case .int(let v):    try c.encode("int", forKey: .type);    try c.encode(v, forKey: .value)
        case .string(let v): try c.encode("string", forKey: .type); try c.encode(v, forKey: .value)
        }
    }
}

/// One app shortcut. `appPath` is intentionally omitted — it is re-resolved
/// locally from `appBundleID` on import so paths stay machine-correct.
struct AppShortcutDTO: Codable, Equatable, Sendable {
    var appBundleID: String
    var appName: String
    var keyCode: Int
    var modifierFlags: Int
    var isEnabled: Bool
    var isVisible: Bool
    var displayOrder: Double
}

/// One builtin preference, keyed by `itemKey` (== `BuiltinItem.rawValue`).
struct BuiltinPreferenceDTO: Codable, Equatable, Sendable {
    var itemKey: String
    var isVisible: Bool
    var displayOrder: Double
    var keyCode: Int?
    var modifierFlags: Int?
}

/// The portable backup payload. `schemaVersion` gates future format migrations.
struct BackupSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var exportedAt: Date
    var appVersion: String
    var deviceName: String?
    var appShortcuts: [AppShortcutDTO]
    var builtinPreferences: [BuiltinPreferenceDTO]
    var settings: [String: SettingValue]
}
