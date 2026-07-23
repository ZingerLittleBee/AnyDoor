import Foundation

/// A Script Plugin's private key-value store (ADR-0009 capability `store`).
///
/// Host-owned, persisted per plugin id *outside* SwiftData, machine-local, and
/// never entered into the backup snapshot. It survives Uninstall/reinstall and
/// runtime teardown, so a reinstalled plugin with the same id finds its data
/// (user story 4/5). Accessed on the main actor like every capability.
@MainActor
public protocol ScriptKeyValueStore: AnyObject {
    func get(_ key: String) -> ScriptValue?
    func set(_ key: String, value: ScriptValue)
    func remove(_ key: String)
    func keys() -> [String]
}

/// A file-backed key-value store: one JSON file per plugin id under the runtime's
/// store directory. Loads eagerly on init and writes through on every mutation,
/// which is what makes the data survive teardown and recreation.
@MainActor
public final class FileScriptKeyValueStore: ScriptKeyValueStore {
    private let fileURL: URL
    private var contents: [String: ScriptValue]

    /// The JSON file backing a plugin's store, `<directory>/<id>.json`.
    public static func fileURL(for id: ScriptPluginID, inDirectory directory: URL) -> URL {
        // Percent-encode the id so an author-namespaced id ("author.plugin")
        // maps to a safe single file name.
        let encoded = id.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? id.rawValue
        return directory.appendingPathComponent("\(encoded).json")
    }

    public init(id: ScriptPluginID, directory: URL) {
        self.fileURL = FileScriptKeyValueStore.fileURL(for: id, inDirectory: directory)
        self.contents = FileScriptKeyValueStore.read(from: fileURL)
    }

    public func get(_ key: String) -> ScriptValue? {
        contents[key]
    }

    public func set(_ key: String, value: ScriptValue) {
        contents[key] = value
        persist()
    }

    public func remove(_ key: String) {
        contents.removeValue(forKey: key)
        persist()
    }

    public func keys() -> [String] {
        Array(contents.keys)
    }

    // MARK: - Persistence

    private static func read(from url: URL) -> [String: ScriptValue] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return [:]
        }
        return dict.mapValues(ScriptValue.init(foundationJSON:))
    }

    private func persist() {
        let object = contents.mapValues(\.foundationJSON)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }
}
