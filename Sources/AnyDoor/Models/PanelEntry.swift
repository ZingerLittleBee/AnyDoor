import Foundation
import AppKit
import PluginInterface

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
        case portRecord(PortRecord)                    // Command-palette-only: listening TCP port process
        case calcResult(CalcResult)                    // Command-palette-only: evaluated expression
        case devTool(DevToolResult)                    // Command-palette-only: developer-tool conversion
        case devToolScopeSuggestion(DevToolScope)      // Command-palette-only: keyword-prefix tool hint
        case conversion(ConversionResult)              // Command-palette-only: unit/time-zone/currency conversion
        case paletteOption(id: String)                 // Command-palette-only: a drilled-in second-level option
        case pluginRow(sourceKey: PluginRowSourceKey, descriptor: PluginRowDescriptor) // Command-palette-only: a plugin-contributed row (ADR-0007)
        case quicklink(id: UUID)                       // Command-palette-only: user-defined Link
        case quicklinkTemplate(id: UUID)               // Command-palette-only: user-defined Search Template
        case quicklinkArgument(id: UUID, argument: String) // Command-palette-only: synthesized template+argument row
    }

    let id: String
    let source: Source
    let displayOrder: Double
    let isVisible: Bool
    let hotkey: HotkeyDescriptor?
    let title: String
    let subtitle: String?
    let searchAliases: [String]
    let symbol: String
    let quicklinkIcon: QuicklinkIconRequest?
    let kind: BuiltinItem.Kind
    let toggleState: Bool?             // .toggle only
    let permission: PermissionStatus

    init(
        id: String,
        source: Source,
        displayOrder: Double,
        isVisible: Bool,
        hotkey: HotkeyDescriptor?,
        title: String,
        subtitle: String?,
        searchAliases: [String] = [],
        symbol: String,
        quicklinkIcon: QuicklinkIconRequest? = nil,
        kind: BuiltinItem.Kind,
        toggleState: Bool?,
        permission: PermissionStatus
    ) {
        self.id = id
        self.source = source
        self.displayOrder = displayOrder
        self.isVisible = isVisible
        self.hotkey = hotkey
        self.title = title
        self.subtitle = subtitle
        self.searchAliases = searchAliases
        self.symbol = symbol
        self.quicklinkIcon = quicklinkIcon
        self.kind = kind
        self.toggleState = toggleState
        self.permission = permission
    }

    /// A palette-synthesized row (drilled-in option, calc result, dev tool,
    /// port, plugin row, installed app, …). These rows share fixed values for
    /// the panel-only fields and derive their id from the source; the factory
    /// keeps the full initializer out of every palette builder.
    static func paletteRow(
        source: Source,
        displayOrder: Double,
        title: String,
        subtitle: String? = nil,
        searchAliases: [String] = [],
        symbol: String,
        quicklinkIcon: QuicklinkIconRequest? = nil,
        kind: BuiltinItem.Kind = .action
    ) -> PanelEntry {
        PanelEntry(
            id: id(for: source),
            source: source,
            displayOrder: displayOrder,
            isVisible: true,
            hotkey: nil,
            title: title,
            subtitle: subtitle,
            searchAliases: searchAliases,
            symbol: symbol,
            quicklinkIcon: quicklinkIcon,
            kind: kind,
            toggleState: nil,
            permission: .notRequired
        )
    }

    static func id(for source: Source) -> String {
        switch source {
        case .appShortcut(let id):                return "app:\(id.uuidString)"
        case .builtin(let item):                  return "builtin:\(item.rawValue)"
        case .installedApp(let bundleID, _):      return "installedApp:\(bundleID)"
        case .portRecord(let record):             return "port:\(record.pid):\(record.port)"
        case .calcResult(let result):             return "calc:\(result.copyText)"
        case .devTool(let result):                return "devTool:\(result.toolID):\(result.output)"
        case .devToolScopeSuggestion(let scope):  return "devToolScope:\(scope.rawValue)"
        case .conversion(let result):             return "conversion:\(result.kind.rawValue):\(result.copyText):\(result.display)"
        case .paletteOption(let id):              return "option:\(id)"
        case .pluginRow(let sourceKey, let descriptor):
            return "pluginRow:\(sourceKey.pluginID.rawValue):\(sourceKey.localID):\(descriptor.id)"
        case .quicklink(let id):                  return "quicklink:\(id.uuidString)"
        case .quicklinkTemplate(let id):          return "quicklinkTemplate:\(id.uuidString)"
        case .quicklinkArgument(let id, let argument):
            return "quicklinkArgument:\(id.uuidString):\(argument)"
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
        case .portRecord: return title
        case .calcResult(let result): return result.display
        case .devTool(let result): return result.output
        case .devToolScopeSuggestion(let scope): return scope.badgeLabel
        case .conversion(let result): return result.display
        case .paletteOption: return title
        case .pluginRow: return title
        case .quicklink: return title
        case .quicklinkTemplate: return title
        case .quicklinkArgument: return title
        }
    }
}
