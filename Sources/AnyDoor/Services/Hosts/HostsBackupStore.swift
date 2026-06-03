import Foundation

/// One-time snapshot of the user's original `/etc/hosts`, plus restore.
/// Snapshot is stored in App Support; restore writes back through a HostsWriter.
struct HostsBackupStore {
    private let backupURL: URL
    private let readLiveHosts: () throws -> String
    /// Test-only injection point: when non-nil, `ensureOriginalBackup()` throws this error instead.
    var backupErrorOverride: Error?

    init(backupDirectory: URL, readLiveHosts: @escaping () throws -> String) {
        self.backupURL = backupDirectory.appendingPathComponent("original.hosts")
        self.readLiveHosts = readLiveHosts
    }

    /// Default production location: App Support/dev.bybee.AnyDoor/hosts-backup.
    static func makeDefault() -> HostsBackupStore {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
            .appendingPathComponent("hosts-backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return HostsBackupStore(backupDirectory: dir, readLiveHosts: {
            try String(contentsOf: URL(fileURLWithPath: "/etc/hosts"), encoding: .utf8)
        })
    }

    var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    func originalContents() -> String? {
        try? String(contentsOf: backupURL, encoding: .utf8)
    }

    /// Snapshot the current `/etc/hosts` exactly once. No-op if a backup exists.
    func ensureOriginalBackup() throws {
        if let override = backupErrorOverride { throw override }
        guard !hasBackup else { return }
        let live = try readLiveHosts()
        try live.data(using: .utf8)?.write(to: backupURL)
    }

    /// Overwrite `/etc/hosts` with the first-run snapshot (destructive; the UI
    /// must confirm before calling this).
    func restoreFirstRunBackup(using writer: HostsWriter) async throws {
        guard let original = originalContents() else {
            throw HostsWriterError.writeFailed("no backup available")
        }
        try await writer.write(original)
    }
}
