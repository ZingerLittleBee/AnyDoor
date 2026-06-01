import Foundation

// Minimal stub for Task 7; Task 8 fills in the rest.
enum ClipboardPreferences {
    static var monitoringEnabled: Bool {
        UserDefaults.standard.object(forKey: "clipboard.monitoringEnabled") as? Bool ?? true
    }

    static var excludedBundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "clipboard.excludedBundleIDs") ?? [])
    }
}
