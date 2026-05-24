import Foundation
import AppKit

/// Permission state for a built-in item that requires external authorization.
enum PermissionStatus: Sendable, Hashable {
    case granted
    case denied
    case undetermined
    case notRequired
}

/// A hotkey binding for display and comparison.
struct HotkeyDescriptor: Hashable, Sendable {
    let keyCode: Int
    let modifierFlags: Int

    /// Ordered key symbols (modifiers first, then the key), one element per keycap.
    var displayParts: [String] {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(KeyCodeMap.name(for: keyCode))
        return parts
    }

    var displayString: String {
        displayParts.joined()
    }
}

/// A unified row visible to the SwiftUI views. Built from one of three sources.
struct PanelEntry: Identifiable, Hashable {
    enum Source: Hashable {
        case appShortcut(UUID)         // KeyBinding.id
        case builtin(BuiltinItem)
    }

    let id: String                     // "app:<uuid>" or "builtin:<key>"
    let source: Source
    let displayOrder: Double
    let isVisible: Bool
    let hotkey: HotkeyDescriptor?
    let title: String
    let subtitle: String?
    let symbol: String
    let kind: BuiltinItem.Kind
    let toggleState: Bool?             // .toggle only
    let permission: PermissionStatus

    static func id(for source: Source) -> String {
        switch source {
        case .appShortcut(let id): return "app:\(id.uuidString)"
        case .builtin(let item):   return "builtin:\(item.rawValue)"
        }
    }

    /// Returns the display title resolved against the active locale.
    /// App shortcut entries return the stored app name; built-in entries
    /// defer to the L10n catalog so the title updates on language change.
    @MainActor
    func localizedTitle() -> String {
        switch source {
        case .appShortcut: return title
        case .builtin(let item): return L(item.titleKey)
        }
    }
}
