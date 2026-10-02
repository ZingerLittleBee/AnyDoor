import Foundation

/// One-time snapshot of the user's original `/etc/hosts`, stored in App Support.
/// `HostsManager.restoreFirstRunBackup()` reads it via `originalContents()` and
/// writes it back through the current `HostsWriter`.
struct HostsBackupStore {
    private let backupURL: URL
    private let readLiveHosts: () throws -> String

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
        guard !hasBackup else { return }
        let live = try readLiveHosts()
        try live.data(using: .utf8)?.write(to: backupURL)
    }
}
