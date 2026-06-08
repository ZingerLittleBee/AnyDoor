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

    /// No-arg form preserved for source compat with existing call sites and
    /// `HotkeyDescriptorTests`. Equivalent to `displayParts(hyperFlags: 0)`.
    var displayParts: [String] { displayParts(hyperFlags: 0) }

    var displayString: String { displayString(hyperFlags: 0) }

    /// Hyper-aware rendering. When `hyperFlags != 0` and the descriptor's
    /// modifier set exactly matches, render as `["✦", key]`. Otherwise use
    /// the existing modifier-glyph layout.
    func displayParts(hyperFlags: Int) -> [String] {
        if hyperFlags != 0 && modifierFlags == hyperFlags {
            return ["✦", KeyCodeMap.name(for: keyCode)]
        }
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(KeyCodeMap.name(for: keyCode))
        return parts
    }

    func displayString(hyperFlags: Int) -> String {
        displayParts(hyperFlags: hyperFlags).joined()
    }
}

/// A unified row visible to the SwiftUI views. Some sources are command-palette-only.
struct PanelEntry: Identifiable, Hashable {
    enum Source: Hashable {
        case appShortcut(UUID)                         // KeyBinding.id
        case builtin(BuiltinItem)
        case installedApp(bundleID: String, path: String) // Command-palette-only: installed but unbound
        case calcResult(CalcResult)                    // Command-palette-only: evaluated expression
        case paletteOption(id: String)                 // Command-palette-only: a drilled-in second-level option
    }

    let id: String
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
        case .appShortcut(let id):                return "app:\(id.uuidString)"
        case .builtin(let item):                  return "builtin:\(item.rawValue)"
        case .installedApp(let bundleID, _):      return "installedApp:\(bundleID)"
        case .calcResult(let result):             return "calc:\(result.copyText)"
        case .paletteOption(let id):              return "option:\(id)"
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
        case .installedApp: return title
        case .calcResult(let result): return result.display
        case .paletteOption: return title
        }
    }
}
