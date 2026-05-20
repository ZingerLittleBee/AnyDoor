import SwiftData
import AppKit

@Model
final class KeyBinding {
    @Attribute(.unique) var id: UUID
    var keyCode: Int
    var modifierFlags: Int
    var appBundleID: String
    var appName: String
    var appPath: String
    /// Whether the hotkey is armed. `false` disables hotkey dispatch even if the row is visible.
    var isEnabled: Bool
    /// Whether the row appears in the App Shortcuts submenu and settings list.
    var isVisible: Bool
    /// Sort weight within the App Shortcuts submenu (lower = earlier). Float so inserts don't renumber.
    var displayOrder: Double
    var createdAt: Date

    init(
        keyCode: Int,
        modifierFlags: Int,
        appBundleID: String,
        appName: String,
        appPath: String,
        isEnabled: Bool = true,
        isVisible: Bool = true,
        displayOrder: Double = 0
    ) {
        self.id = UUID()
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.appBundleID = appBundleID
        self.appName = appName
        self.appPath = appPath
        self.isEnabled = isEnabled
        self.isVisible = isVisible
        self.displayOrder = displayOrder
        self.createdAt = Date()
    }

    @Transient var displayKey: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(KeyCodeMap.name(for: keyCode))
        return parts.joined()
    }
}
