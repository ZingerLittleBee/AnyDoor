import Foundation

/// Notification Center's own names for its dismiss actions and for its
/// windows, read from its string table at runtime. Apple re-translates these
/// labels between releases, so a hardcoded list would go stale; reading the
/// system's table follows those translations, as long as the actions keep
/// taking their names from these keys.
struct SystemNotificationDismissLabels: Sendable, Equatable {
    /// Keys of Notification Center's `Localizable` table whose values name its
    /// dismiss actions, highest priority first: a stack's "Clear All" is
    /// expected to close the whole group, so it wins over "Close" when an
    /// element offers both. Deliberately absent: "Clear" (German "Löschen" is
    /// also the name apps give their own Delete action), "Clear
    /// Notifications…" (likely the panel's confirmation flow, going by the
    /// strings Notification Center ships) and "Remove" (likely a widget
    /// action).
    static let actionKeys = ["Clear All", "Dismiss All", "Close", "Dismiss"]

    /// Key of Notification Center's own name, which is expected to title its
    /// panel window.
    static let windowTitleKey = "Notification Center"

    /// Accepted labels for each `actionKeys` entry, in the same order. A set is
    /// empty when the table has no value for that key.
    var actionLabels: [Set<String>]
    /// Accepted titles of Notification Center's panel window, from the same
    /// localizations as the action labels. Banner windows are recognized by
    /// their subrole instead.
    var windowTitles: Set<String>
    /// Whether the labels come from the one localization Notification Center
    /// runs in. False means its language was unknown, so every localization's
    /// labels are accepted.
    var isLanguageKnown: Bool

    /// The bundle to read when the running Notification Center reports none.
    static let defaultBundleURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/NotificationCenter.app",
        isDirectory: true
    )

    /// Resolves the labels from the Notification Center bundle's own string
    /// table.
    /// - Parameter languages: The language Notification Center runs in, or the
    ///   user's language list, most preferred first. Empty when unknown.
    static func resolve(bundleURL: URL, languages: [String]) -> SystemNotificationDismissLabels {
        make(tables: SystemNotificationStringTables.load(bundleURL: bundleURL), languages: languages)
    }

    /// Builds the labels from tables already read (localization -> key ->
    /// value). A known language uses only its own localization; the union of
    /// all localizations is reserved for an unknown language, so a foreign
    /// word is never matched against an app's own notification actions.
    static func make(
        tables: [String: [String: String]],
        languages: [String]
    ) -> SystemNotificationDismissLabels {
        let active = languages.isEmpty
            ? nil
            : Bundle.preferredLocalizations(from: tables.keys.sorted(), forPreferences: languages)
                .first
                .flatMap { tables[$0] }
        let sources = active.map { [$0] } ?? Array(tables.values)
        func labels(for key: String) -> Set<String> {
            Set(sources.compactMap { $0[key] })
        }
        return SystemNotificationDismissLabels(
            actionLabels: actionKeys.map(labels(for:)),
            windowTitles: labels(for: windowTitleKey),
            isLanguageKnown: active != nil
        )
    }
}

/// Reads a bundle's `Localizable` string table as localization -> key ->
/// value: the single `Localizable.loctable` (a property list keyed by
/// localization) that current systems ship, or the per-localization
/// `<name>.lproj/Localizable.strings` files of older layouts. Reads the files
/// directly instead of going through `Bundle` lookups, whose locale selection
/// varies across macOS releases.
enum SystemNotificationStringTables {
    private static let table = "Localizable"

    static func load(bundleURL: URL) -> [String: [String: String]] {
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let loctable = loctableTables(at: resources.appendingPathComponent("\(table).loctable"))
        return loctable.isEmpty ? lprojTables(in: resources) : loctable
    }

    private static func loctableTables(at url: URL) -> [String: [String: String]] {
        guard let root = propertyList(at: url) else { return [:] }
        var tables: [String: [String: String]] = [:]
        for (localization, value) in root {
            // Skips non-table entries such as the `LocProvenance` bookkeeping
            // map, which holds no string values.
            guard let entries = value as? [String: Any] else { continue }
            let strings = entries.compactMapValues { $0 as? String }
            if !strings.isEmpty { tables[localization] = strings }
        }
        return tables
    }

    private static func lprojTables(in resources: URL) -> [String: [String: String]] {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil
        )) ?? []
        var tables: [String: [String: String]] = [:]
        for directory in directories where directory.pathExtension == "lproj" {
            let localization = directory.deletingPathExtension().lastPathComponent
            guard localization != "Base",
                  let root = propertyList(at: directory.appendingPathComponent("\(table).strings"))
            else { continue }
            let strings = root.compactMapValues { $0 as? String }
            if !strings.isEmpty { tables[localization] = strings }
        }
        return tables
    }

    /// Parses binary, XML, and text (`"key" = "value";`) property lists alike.
    private static func propertyList(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
