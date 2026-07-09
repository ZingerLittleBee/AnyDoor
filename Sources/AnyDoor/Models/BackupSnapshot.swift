import Foundation

/// Type-tagged scalar for whitelisted UserDefaults values so the JSON stays
/// strongly typed and decodes back into the correct Swift type.
enum SettingValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)
    case stringArray([String])

    private enum CodingKeys: String, CodingKey { case type, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "bool":   self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int":    self = .int(try c.decode(Int.self, forKey: .value))
        case "string": self = .string(try c.decode(String.self, forKey: .value))
        case "stringArray": self = .stringArray(try c.decode([String].self, forKey: .value))
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
        case .stringArray(let v):
            try c.encode("stringArray", forKey: .type)
            try c.encode(v, forKey: .value)
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

/// One user-defined Quicklink. Machine-local icon/favicon caches are omitted.
struct QuicklinkDTO: Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var keyword: String?
    var link: String
    var openWithBundleID: String?
    var keyCode: Int?
    var modifierFlags: Int?
    var isVisible: Bool
    var displayOrder: Double
    var createdAt: Date
}

/// The portable backup payload. `schemaVersion` gates future format migrations.
struct BackupSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var exportedAt: Date
    var appVersion: String
    var deviceName: String?
    var appShortcuts: [AppShortcutDTO]
    var builtinPreferences: [BuiltinPreferenceDTO]
    var quicklinks: [QuicklinkDTO]
    var settings: [String: SettingValue]

    init(
        schemaVersion: Int,
        exportedAt: Date,
        appVersion: String,
        deviceName: String?,
        appShortcuts: [AppShortcutDTO],
        builtinPreferences: [BuiltinPreferenceDTO],
        quicklinks: [QuicklinkDTO] = [],
        settings: [String: SettingValue]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.appShortcuts = appShortcuts
        self.builtinPreferences = builtinPreferences
        self.quicklinks = quicklinks
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case exportedAt
        case appVersion
        case deviceName
        case appShortcuts
        case builtinPreferences
        case quicklinks
        case settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        appShortcuts = try c.decode([AppShortcutDTO].self, forKey: .appShortcuts)
        builtinPreferences = try c.decode([BuiltinPreferenceDTO].self, forKey: .builtinPreferences)
        quicklinks = try c.decodeIfPresent([QuicklinkDTO].self, forKey: .quicklinks) ?? []
        settings = try c.decode([String: SettingValue].self, forKey: .settings)
    }
}
