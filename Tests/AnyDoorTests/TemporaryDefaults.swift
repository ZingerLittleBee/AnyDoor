import Foundation
import XCTest

/// A UserDefaults suite stored in its own temporary directory.
///
/// CFPreferences keeps a suite whose name is an absolute path at
/// `<name>.plist`, so a test suite never writes to ~/Library/Preferences, and
/// removing the directory removes every trace. A named suite would leave an
/// empty plist there even after `removePersistentDomain(forName:)`.
struct TemporaryDefaultsSuite: Sendable {
    let directory: URL
    let name: String

    init(label: String = "defaults") {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnyDoorTests-Defaults-\(UUID().uuidString)",
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        name = directory.appendingPathComponent(label).path
    }

    /// A new handle on the suite. Handles share one store, which is how a
    /// test models a relaunch.
    func makeDefaults() -> UserDefaults {
        // UserDefaults refuses only the app's own domain and the global one.
        UserDefaults(suiteName: name)!
    }

    /// Empties the suite and deletes its directory. A write after this lands
    /// in a recreated temporary directory, never in ~/Library/Preferences.
    func remove() {
        makeDefaults().removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: directory)
    }
}

extension XCTestCase {
    /// An empty suite private to this test, removed at teardown, including
    /// after a failed assertion or a thrown error.
    func makeTemporaryDefaults(_ label: String = "defaults") -> UserDefaults {
        makeTemporaryDefaultsSuite(label).makeDefaults()
    }

    /// The suite itself, for a test that needs its location or reopens it.
    func makeTemporaryDefaultsSuite(
        _ label: String = "defaults"
    ) -> TemporaryDefaultsSuite {
        let suite = TemporaryDefaultsSuite(label: label)
        addTeardownBlock { suite.remove() }
        return suite
    }
}
