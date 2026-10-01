import Foundation

/// Frozen copies of the pre-v2 code that deletes files from the
/// `ClipboardHistory` folder (`ClipboardHistoryStore` in the release tags
/// named below, with the store's `historyDirectoryProvider()` passed in as
/// `directory`). Those releases stay installable, so this behaviour is a fixed
/// contract the store root must stay out of reach of, not free-form test code:
/// change it only to match a shipped tag.
///
/// Both sweeps enumerate only the folder's top level, so a sibling folder is
/// out of their reach; a store inside the folder is not.
enum PreV2ClipboardHistorySweep {
    /// `removeOrphanScreenshotFiles(keeping:)` from v1.8.0 through v4.1.1:
    /// deletes every top-level child that no surviving legacy row names. It
    /// runs automatically whenever history is pruned (on launch and after
    /// captures), and no legacy row ever names `history.sqlite` or `payloads`.
    static func removeOrphanFiles(
        in directory: URL,
        keeping survivingFiles: Set<String>
    ) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        // Copied files keep arbitrary extensions, so do not restrict by ".png".
        for url in contents {
            if !survivingFiles.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// `removeOrphanScreenshotFiles(keeping:)` from v1.2.0 through v1.7.0:
    /// the same sweep restricted to `.png` children.
    static func removeOrphanPNGFiles(
        in directory: URL,
        keeping survivingFiles: Set<String>
    ) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in contents where url.pathExtension.lowercased() == "png" {
            if !survivingFiles.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// The folder wipe inside `clearAll()` from v1.2.0 through v4.1.1, run
    /// when the user clears history: deletes every top-level child.
    static func clearAll(in directory: URL) {
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            for url in contents {
                try? fm.removeItem(at: url)
            }
        }
    }
}
