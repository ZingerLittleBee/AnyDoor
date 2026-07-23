import Foundation

/// A refusal to load a package's manifest. Every case is side-effect-free: the
/// runtime state and the on-disk store are untouched when a manifest is refused
/// (user story 3 — a bad package can never half-install).
public enum ScriptManifestError: Error, Equatable {
    /// `manifest.json` was missing or unreadable at the package directory.
    case fileUnreadable
    /// The manifest bytes were not valid JSON.
    case invalidJSON
    /// A required field was absent or the wrong type (the field name is carried).
    case missingField(String)
    /// `apiVersion` names a version this runtime does not implement.
    case unknownAPIVersion(Int)
    /// A declared capability string names no known capability (ADR-0009).
    case unknownCapability(String)
}

/// A validated Script Plugin manifest.
///
/// Construct only through ``load(fromDirectory:)`` / ``decode(from:)`` so every
/// instance is already validated — there is no way to hold an invalid manifest.
public struct ScriptPluginManifest: Sendable, Equatable {
    /// The single `apiVersion` this milestone implements. Required and gated at
    /// load with a typed refusal; the API may break freely until the store
    /// milestone (ADR-0008/0009).
    public static let supportedAPIVersion = 1

    /// The manifest file name inside a package directory.
    public static let fileName = "manifest.json"

    public let id: ScriptPluginID
    public let name: String
    public let description: String
    public let version: String
    public let apiVersion: Int
    /// The single ES-module bundle file name inside the package directory.
    public let entryPoint: String
    public let capabilities: Set<ScriptCapability>
    /// Optional per-language display names keyed by language code (e.g. "zh").
    public let localizedNames: [String: String]
    /// Optional per-language descriptions keyed by language code.
    public let localizedDescriptions: [String: String]

    public init(
        id: ScriptPluginID,
        name: String,
        description: String,
        version: String,
        apiVersion: Int,
        entryPoint: String,
        capabilities: Set<ScriptCapability>,
        localizedNames: [String: String] = [:],
        localizedDescriptions: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.apiVersion = apiVersion
        self.entryPoint = entryPoint
        self.capabilities = capabilities
        self.localizedNames = localizedNames
        self.localizedDescriptions = localizedDescriptions
    }

    // MARK: - Localized display

    /// The display name for a language, falling back to the base `name` when the
    /// manifest declares no per-language override (user story 22). `code` is a
    /// bare language code such as "zh" or "en".
    public func displayName(forLanguageCode code: String?) -> String {
        Self.localizedValue(localizedNames, code: code, base: name)
    }

    /// The display description for a language, falling back to the base
    /// `description` when no per-language override exists.
    public func displayDescription(forLanguageCode code: String?) -> String {
        Self.localizedValue(localizedDescriptions, code: code, base: description)
    }

    private static func localizedValue(_ map: [String: String], code: String?, base: String) -> String {
        if let code, let value = map[code], !value.isEmpty { return value }
        return base
    }

    // MARK: - Loading

    /// Read and validate `manifest.json` from a package directory.
    public static func load(fromDirectory directory: URL) throws -> ScriptPluginManifest {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            throw ScriptManifestError.fileUnreadable
        }
        return try decode(from: data)
    }

    /// Validate manifest bytes without touching the filesystem.
    public static func decode(from data: Data) throws -> ScriptPluginManifest {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else {
            throw ScriptManifestError.invalidJSON
        }

        let id = try requireString("id", in: json)
        let name = try requireString("name", in: json)
        let description = try requireString("description", in: json)
        let version = try requireString("version", in: json)

        guard let apiVersion = json["apiVersion"] as? Int else {
            throw ScriptManifestError.missingField("apiVersion")
        }
        guard apiVersion == supportedAPIVersion else {
            throw ScriptManifestError.unknownAPIVersion(apiVersion)
        }

        // Entry point is optional; a single-bundle package defaults to bundle.js.
        let entryPoint = (json["entryPoint"] as? String) ?? "bundle.js"

        let capabilities = try parseCapabilities(json["capabilities"])

        return ScriptPluginManifest(
            id: ScriptPluginID(id),
            name: name,
            description: description,
            version: version,
            apiVersion: apiVersion,
            entryPoint: entryPoint,
            capabilities: capabilities,
            localizedNames: json["localizedNames"] as? [String: String] ?? [:],
            localizedDescriptions: json["localizedDescriptions"] as? [String: String] ?? [:]
        )
    }

    private static func requireString(_ field: String, in json: [String: Any]) throws -> String {
        guard let value = json[field] as? String, !value.isEmpty else {
            throw ScriptManifestError.missingField(field)
        }
        return value
    }

    private static func parseCapabilities(_ raw: Any?) throws -> Set<ScriptCapability> {
        // Absent capabilities means the plugin declared none: a pure display
        // plugin is valid. An explicit non-array value is malformed.
        guard let raw else { return [] }
        guard let strings = raw as? [String] else {
            throw ScriptManifestError.missingField("capabilities")
        }
        var capabilities: Set<ScriptCapability> = []
        for string in strings {
            guard let capability = ScriptCapability(manifestKey: string) else {
                throw ScriptManifestError.unknownCapability(string)
            }
            capabilities.insert(capability)
        }
        return capabilities
    }
}
