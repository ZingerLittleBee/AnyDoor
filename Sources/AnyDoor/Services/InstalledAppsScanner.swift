import AppKit
import Foundation

struct InstalledApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let displayName: String
    let path: String
    var id: String { bundleID }

    var isSystemApp: Bool { path.hasPrefix("/System/") }
}

/// Stateless filesystem scan for installed `.app` bundles. Deliberately
/// `nonisolated`: it only touches `FileManager`/`Bundle` and returns a Sendable
/// `[InstalledApp]`, so callers can (and the command palette does) run it off
/// the main actor via `Task.detached` to keep summoning the palette from
/// blocking on a `/Applications` walk + per-app Info.plist read.
enum InstalledAppsScanner {
    /// Roots scanned for `.app` bundles (direct children only).
    private static let scanRoots: [String] = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// Apps that don't live in any of `scanRoots` but should always be offered.
    private static let extraAppPaths: [String] = [
        "/System/Library/CoreServices/Finder.app",
    ]

    static func scan() -> [InstalledApp] {
        let fm = FileManager.default
        var byBundleID: [String: InstalledApp] = [:]

        for root in scanRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(entry)
                if let app = makeApp(at: path), byBundleID[app.bundleID] == nil {
                    byBundleID[app.bundleID] = app
                }
            }
        }

        for path in extraAppPaths {
            guard fm.fileExists(atPath: path) else { continue }
            if let app = makeApp(at: path), byBundleID[app.bundleID] == nil {
                byBundleID[app.bundleID] = app
            }
        }

        return byBundleID.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func makeApp(at path: String) -> InstalledApp? {
        let url = URL(fileURLWithPath: path)
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier,
              !bundleID.isEmpty else {
            return nil
        }
        let info = bundle.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(bundleID: bundleID, displayName: name, path: path)
    }
}
