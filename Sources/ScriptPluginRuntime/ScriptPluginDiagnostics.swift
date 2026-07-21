import Foundation

/// The class of a Script Plugin diagnostic event. The three the runtime records
/// are exactly the three the spec calls out (018 Diagnostics; ticket 023): a
/// package the runtime refused to load, a watchdog kill, and a capability the
/// host rejected. Kept a closed enum so a log reader (and the tests) can key on
/// the category rather than parse free text.
public enum ScriptDiagnosticCategory: String, Sendable {
    /// The runtime could not bring a context up — an unreadable bundle, a bundle
    /// that threw while evaluating, or a plugin that never registered.
    case loadRefused
    /// An invocation exceeded the watchdog deadline and its context was destroyed.
    case watchdogKill
    /// A capability call was rejected inside the host (message carried).
    case capabilityError
}

/// One diagnostic event attributed to a single plugin. Sendable so it can be
/// recorded from a plugin's background queue as well as the main actor.
public struct ScriptDiagnosticEvent: Sendable, Equatable {
    public let pluginID: ScriptPluginID
    public let category: ScriptDiagnosticCategory
    public let message: String
    public let date: Date

    public init(
        pluginID: ScriptPluginID,
        category: ScriptDiagnosticCategory,
        message: String,
        date: Date = Date()
    ) {
        self.pluginID = pluginID
        self.category = category
        self.message = message
        self.date = date
    }
}

/// Sink for per-plugin diagnostic events. The runtime records load refusals,
/// watchdog kills, and capability errors here for *every* Script Plugin — dev or
/// installed — so a failure in the field is diagnosable from a log file, not just
/// a toast (user story 21).
///
/// `Sendable` because the runtime records from a plugin's serial queue; a
/// file-backed sink serializes its own writes.
public protocol ScriptPluginDiagnostics: Sendable {
    func record(_ event: ScriptDiagnosticEvent)
}

/// A diagnostics sink that drops every event. The runtime's default, so a
/// runtime built without a log (most tests) records nothing.
public struct NullScriptPluginDiagnostics: ScriptPluginDiagnostics {
    public init() {}
    public func record(_ event: ScriptDiagnosticEvent) {}
}

/// A file-backed diagnostics sink: one append-only log file per plugin id under a
/// logs directory, `<directory>/<encoded-id>.log`. Writes are serialized on a
/// private queue so events from different plugin queues never interleave a line.
///
/// `@unchecked Sendable` is sound because every access to the filesystem happens
/// inside a block dispatched on `queue`; no mutable state is shared otherwise.
public final class FileScriptPluginLog: ScriptPluginDiagnostics, @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "dev.bybee.AnyDoor.script-plugin.log")
    private let formatter: ISO8601DateFormatter

    public init(directory: URL) {
        self.directory = directory
        self.formatter = ISO8601DateFormatter()
    }

    /// The log file backing a plugin, `<directory>/<encoded-id>.log`. Uses the
    /// same percent-encoding scheme as the private store so an author-namespaced
    /// id ("author.plugin") maps to one safe file name.
    public static func fileURL(for id: ScriptPluginID, inDirectory directory: URL) -> URL {
        let encoded = id.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? id.rawValue
        return directory.appendingPathComponent("\(encoded).log")
    }

    public func record(_ event: ScriptDiagnosticEvent) {
        let line = "\(formatter.string(from: event.date)) [\(event.category.rawValue)] \(event.message)\n"
        let url = Self.fileURL(for: event.pluginID, inDirectory: directory)
        queue.async { [directory] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Read a plugin's log back (test/diagnostic seam). Flushes the write queue
    /// first so a just-recorded event is visible.
    public func contents(for id: ScriptPluginID) -> String {
        queue.sync {}
        let url = Self.fileURL(for: id, inDirectory: directory)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
