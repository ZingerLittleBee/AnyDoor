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
    var isEnabled: Bool
    var createdAt: Date

    init(
        keyCode: Int,
        modifierFlags: Int,
        appBundleID: String,
        appName: String,
        appPath: String,
        isEnabled: Bool = true
    ) {
        self.id = UUID()
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.appBundleID = appBundleID
        self.appName = appName
        self.appPath = appPath
        self.isEnabled = isEnabled
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
