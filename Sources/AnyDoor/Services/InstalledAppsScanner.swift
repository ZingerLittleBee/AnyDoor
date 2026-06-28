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
    /// Roots scanned for `.app` bundles.
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

    /// How deep to descend from each root looking for `.app` bundles. Many apps
    /// don't sit directly under `/Applications` but one level inside a vendor
    /// folder — e.g. `Setapp/CleanShot X.app`, `Adobe Photoshop 2026/Adobe
    /// Photoshop 2026.app`, or a symlink `Adobe Creative Cloud/Adobe Creative
    /// Cloud` pointing at the real bundle. A depth of 2 covers these while
    /// keeping the walk cheap (we never descend into a bundle, and Spotlight is
    /// unreliable — it can be index-disabled — so we don't rely on `mdfind`).
    private static let maxDepth = 2

    static func scan() -> [InstalledApp] {
        scan(roots: scanRoots, extraAppPaths: extraAppPaths)
    }

    /// Testable core: scans the given roots (bounded recursion) plus any extra
    /// explicit bundle paths, deduping by bundle identifier.
    static func scan(roots: [String], extraAppPaths: [String]) -> [InstalledApp] {
        let fm = FileManager.default
        var byBundleID: [String: InstalledApp] = [:]

        func record(_ app: InstalledApp) {
            if byBundleID[app.bundleID] == nil {
                byBundleID[app.bundleID] = app
            }
        }

        func walk(_ dir: String, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries {
                // Skip hidden entries (e.g. ".Uninstall …_bkp" alias backups).
                if entry.hasPrefix(".") { continue }
                let entryPath = (dir as NSString).appendingPathComponent(entry)
                // Resolve symlinks so links without a ".app" suffix (e.g. the
                // "Adobe Creative Cloud" alias) still resolve to their bundle.
                let resolved = URL(fileURLWithPath: entryPath).resolvingSymlinksInPath().path
                if resolved.hasSuffix(".app") {
                    // Application bundle (a leaf): record it, never descend into
                    // it. For links whose on-disk name differs from the bundle
                    // name, prefer the name shown in `/Applications`.
                    let preferredName = entry.hasSuffix(".app") ? nil : entry
                    if let app = makeApp(at: resolved, preferredName: preferredName) {
                        record(app)
                    }
                } else if depth < maxDepth {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue {
                        walk(resolved, depth: depth + 1)
                    }
                }
            }
        }

        for root in roots {
            walk(root, depth: 0)
        }

        for path in extraAppPaths where fm.fileExists(atPath: path) {
            if let app = makeApp(at: path, preferredName: nil) {
                record(app)
            }
        }

        return byBundleID.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func makeApp(at path: String, preferredName: String?) -> InstalledApp? {
        let url = URL(fileURLWithPath: path)
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier,
              !bundleID.isEmpty else {
            return nil
        }
        let info = bundle.infoDictionary
        let name = preferredName
            ?? (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(bundleID: bundleID, displayName: name, path: path)
    }
}
