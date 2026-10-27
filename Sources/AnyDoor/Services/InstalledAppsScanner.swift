import AppKit
import Foundation

struct InstalledApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let displayName: String
    let path: String
    /// Unlocalized Info.plist names and the on-disk basename, when they differ
    /// from `displayName`. Palette search treats these as aliases so typing
    /// the internal bundle name still finds the localized display name.
    let searchAliases: [String]
    var id: String { bundleID }

    var isSystemApp: Bool { path.hasPrefix("/System/") }
}

/// Where a previously recorded app (an app shortcut's bundle ID and path) is
/// now, relative to a fresh scan.
enum RecordedAppLocation: Equatable, Sendable {
    /// The recorded path still holds the app.
    case unchanged
    /// The recorded path no longer holds the app, but a copy with the same
    /// bundle identifier is installed elsewhere, typically a reinstall under a
    /// new bundle name such as "T3 Code (Nightly)" → "T3 Code (Beta)".
    case moved(InstalledApp)
    /// No installed copy remains.
    case missing
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
    /// keeping the walk cheap (we never walk a bundle's payload, and Spotlight
    /// is unreliable — it can be index-disabled — so we don't rely on `mdfind`).
    private static let maxDepth = 2

    /// Folders inside an app bundle where it ships companion apps people launch
    /// directly: Xcode keeps Instruments, DeviceHub, and Accessibility
    /// Inspector in `Contents/Applications`, and older Xcode releases keep
    /// Simulator in `Contents/Developer/Applications`. Only these folders are
    /// read, one level deep; the rest of the bundle stays unwalked.
    private static let embeddedAppDirectories = [
        "Contents/Applications",
        "Contents/Developer/Applications",
    ]

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

        func recordBundle(at path: String, preferredName: String?) {
            guard let app = makeApp(at: path, preferredName: preferredName) else { return }
            record(app)
            for subdirectory in embeddedAppDirectories {
                let dir = (path as NSString).appendingPathComponent(subdirectory)
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where !entry.hasPrefix(".") {
                    let entryPath = (dir as NSString).appendingPathComponent(entry)
                    let resolved = URL(fileURLWithPath: entryPath).resolvingSymlinksInPath().path
                    // Hosts also embed agents here (Google Drive's FinderHelper,
                    // Finder's AirDrop and Recents shims) that are not apps a
                    // person opens from a launcher.
                    guard resolved.hasSuffix(".app"),
                          !isAgent(at: resolved),
                          let embedded = makeApp(at: resolved, preferredName: nil) else { continue }
                    record(embedded)
                }
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
                    // Application bundle: record it and its embedded companion
                    // apps, but never walk into it. For links whose on-disk
                    // name differs from the bundle name, prefer the name shown
                    // in `/Applications`.
                    let preferredName = entry.hasSuffix(".app") ? nil : entry
                    recordBundle(at: resolved, preferredName: preferredName)
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
            recordBundle(at: path, preferredName: nil)
        }

        return byBundleID.values.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Locate a recorded app among `installed`. A recorded path that still
    /// holds the bundle wins even when the scan deduped to another copy (e.g.
    /// Xcode-beta beside Xcode), so a deliberate choice is never re-pointed;
    /// otherwise the scanned copy with the same bundle identifier replaces it.
    static func locate(
        bundleID: String,
        recordedPath: String,
        in installed: [InstalledApp]
    ) -> RecordedAppLocation {
        if !recordedPath.isEmpty,
           FileManager.default.fileExists(atPath: recordedPath),
           Bundle(path: recordedPath)?.bundleIdentifier == bundleID {
            return .unchanged
        }
        if let app = installed.first(where: { $0.bundleID == bundleID }) {
            return .moved(app)
        }
        return .missing
    }

    private static func makeApp(at path: String, preferredName: String?) -> InstalledApp? {
        let url = URL(fileURLWithPath: path)
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier,
              !bundleID.isEmpty else {
            return nil
        }
        // `object(forInfoDictionaryKey:)` returns the localized value when an
        // InfoPlist.strings file exists. `infoDictionary` does not — it would
        // surface an internal bundle name and miss a query for the name shown
        // in Finder.
        let localized = nonEmptyString(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName"))
            ?? nonEmptyString(bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String))
        let unlocalized = nonEmptyString(bundle.infoDictionary?["CFBundleDisplayName"])
            ?? nonEmptyString(bundle.infoDictionary?[kCFBundleNameKey as String])
        let basename = url.deletingPathExtension().lastPathComponent
        let name = preferredName ?? localized ?? unlocalized ?? basename
        return InstalledApp(
            bundleID: bundleID,
            displayName: name,
            path: path,
            searchAliases: aliases(
                forDisplayName: name,
                localized: localized,
                unlocalized: unlocalized,
                basename: basename
            )
        )
    }

    /// Whether the bundle declares itself a UI-less agent or background-only
    /// process. Info.plists store these flags as booleans or as "1"/"YES"
    /// strings.
    private static func isAgent(at path: String) -> Bool {
        guard let info = Bundle(path: path)?.infoDictionary else { return false }
        return ["LSUIElement", "LSBackgroundOnly"].contains { key in
            switch info[key] {
            case let flag as Bool:
                return flag
            case let flag as String:
                return ["1", "yes", "true"].contains(flag.lowercased())
            default:
                return false
            }
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func aliases(
        forDisplayName name: String,
        localized: String?,
        unlocalized: String?,
        basename: String
    ) -> [String] {
        var seen: Set<String> = [folded(name)]
        var result: [String] = []
        for candidate in [localized, unlocalized, basename] {
            guard let candidate, !candidate.isEmpty else { continue }
            if seen.insert(folded(candidate)).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: .caseInsensitive, locale: .current)
    }
}
