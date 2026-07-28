import Foundation

/// Identity of one syncable configuration record. Encoded as a prefixed
/// string (`appShortcut:<bundleID>`, …) so the document JSON stays a flat
/// object keyed by record.
enum SyncKey: Hashable, Sendable {
    case appShortcut(bundleID: String)
    case builtinPreference(itemKey: String)
    case quicklink(id: UUID)
    case setting(key: String)

    var rawKey: String {
        switch self {
        case .appShortcut(let bundleID): return "appShortcut:\(bundleID)"
        case .builtinPreference(let itemKey): return "builtinPreference:\(itemKey)"
        case .quicklink(let id): return "quicklink:\(id.uuidString)"
        case .setting(let key): return "setting:\(key)"
        }
    }

    /// Fails on an unknown prefix or malformed remainder — a peer running a
    /// newer schema, or a corrupt file. Callers skip what they can't parse.
    init?(rawKey: String) {
        guard let separator = rawKey.firstIndex(of: ":") else { return nil }
        let kind = String(rawKey[..<separator])
        let rest = String(rawKey[rawKey.index(after: separator)...])
        guard !rest.isEmpty else { return nil }
        switch kind {
        case "appShortcut": self = .appShortcut(bundleID: rest)
        case "builtinPreference": self = .builtinPreference(itemKey: rest)
        case "quicklink":
            guard let id = UUID(uuidString: rest) else { return nil }
            self = .quicklink(id: id)
        case "setting": self = .setting(key: rest)
        default: return nil
        }
    }
}

/// The value side of one record, reusing the backup DTOs so sync and Config
/// Backup cannot drift apart on what a record contains.
enum SyncPayload: Codable, Equatable, Sendable {
    case appShortcut(AppShortcutDTO)
    case builtinPreference(BuiltinPreferenceDTO)
    case quicklink(QuicklinkDTO)
    case setting(SettingValue)

    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "appShortcut": self = .appShortcut(try c.decode(AppShortcutDTO.self, forKey: .value))
        case "builtinPreference": self = .builtinPreference(try c.decode(BuiltinPreferenceDTO.self, forKey: .value))
        case "quicklink": self = .quicklink(try c.decode(QuicklinkDTO.self, forKey: .value))
        case "setting": self = .setting(try c.decode(SettingValue.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown SyncPayload kind \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .appShortcut(let v):
            try c.encode("appShortcut", forKey: .kind); try c.encode(v, forKey: .value)
        case .builtinPreference(let v):
            try c.encode("builtinPreference", forKey: .kind); try c.encode(v, forKey: .value)
        case .quicklink(let v):
            try c.encode("quicklink", forKey: .kind); try c.encode(v, forKey: .value)
        case .setting(let v):
            try c.encode("setting", forKey: .kind); try c.encode(v, forKey: .value)
        }
    }
}

/// One record's state: its payload (or a tombstone when `payload == nil`)
/// plus the clock of the edit that produced it.
struct SyncEntry: Codable, Equatable, Sendable {
    var payload: SyncPayload?
    var clock: SyncTimestamp

    var isTombstone: Bool { payload == nil }

    private enum CodingKeys: String, CodingKey { case payload, clock }

    init(payload: SyncPayload?, clock: SyncTimestamp) {
        self.payload = payload
        self.clock = clock
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        payload = try c.decodeIfPresent(SyncPayload.self, forKey: .payload)
        clock = try c.decode(SyncTimestamp.self, forKey: .clock)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(payload, forKey: .payload)
        try c.encode(clock, forKey: .clock)
    }
}

/// A machine's mergeable view of its portable configuration (ADR-0010).
/// Merge is per-key LWW over `SyncTimestamp`'s total order, which makes it
/// commutative, associative, and idempotent — pinned by property tests.
struct SyncDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var deviceID: String
    var deviceName: String?
    var entries: [SyncKey: SyncEntry]

    init(
        schemaVersion: Int = SyncDocument.currentSchemaVersion,
        deviceID: String,
        deviceName: String? = nil,
        entries: [SyncKey: SyncEntry] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.entries = entries
    }

    /// Per-key LWW. The result keeps `self`'s identity fields; merge only
    /// combines record states. Unparseable peer keys were already dropped at
    /// decode time.
    func merged(with other: SyncDocument) -> SyncDocument {
        var result = self
        for (key, remote) in other.entries {
            if let local = result.entries[key] {
                if local.clock < remote.clock {
                    result.entries[key] = remote
                }
            } else {
                result.entries[key] = remote
            }
        }
        return result
    }

    /// Drop tombstones whose deletion happened before `cutoffWallMillis`.
    /// Live entries are never pruned. The cutoff must be far larger than any
    /// realistic offline window (~90 days) or a returning machine could
    /// resurrect the deleted record.
    func prunedTombstones(before cutoffWallMillis: Int64) -> SyncDocument {
        var result = self
        result.entries = entries.filter { _, entry in
            !(entry.isTombstone && entry.clock.wallMillis < cutoffWallMillis)
        }
        return result
    }

    // MARK: - Codable (entries as a flat raw-keyed JSON object)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, deviceID, deviceName, entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        let raw = try c.decode([String: SyncEntry].self, forKey: .entries)
        var parsed: [SyncKey: SyncEntry] = [:]
        parsed.reserveCapacity(raw.count)
        for (rawKey, entry) in raw {
            // Skip keys this build doesn't know; a newer peer's extra records
            // must not fail the whole document.
            guard let key = SyncKey(rawKey: rawKey) else { continue }
            parsed[key] = entry
        }
        entries = parsed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encodeIfPresent(deviceName, forKey: .deviceName)
        let raw = Dictionary(uniqueKeysWithValues: entries.map { ($0.rawKey, $1) })
        try c.encode(raw, forKey: .entries)
    }
}
