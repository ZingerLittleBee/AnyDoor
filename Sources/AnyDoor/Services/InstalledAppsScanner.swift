import AppKit
import Foundation

struct InstalledApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let displayName: String
    let path: String
    var id: String { bundleID }

    var isSystemApp: Bool { path.hasPrefix("/System/") }
}

@MainActor
enum InstalledAppsScanner {
    static func scan() -> [InstalledApp] {
        return []
    }
}
