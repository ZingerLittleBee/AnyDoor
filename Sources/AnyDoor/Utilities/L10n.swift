import SwiftUI

/// Type-safe namespace for every translatable UI string. Keys are dot-separated
/// to mirror the structure in `Localizable.xcstrings`. Cases are added by
/// migration tasks; the catalog must contain a matching entry for each case.
enum L10n {
    enum Key: String, CaseIterable, Sendable {
        case builtinAppShortcuts = "builtin.appShortcuts"
        case builtinAutoHideMenuBar = "builtin.autoHideMenuBar"
        case builtinDarkMode = "builtin.darkMode"
        case builtinDisplaySleep = "builtin.displaySleep"
        case builtinEmptyTrash = "builtin.emptyTrash"
        case builtinFlushDNS = "builtin.flushDNS"
        case builtinHideDesktopIcons = "builtin.hideDesktopIcons"
        case builtinHideDock = "builtin.hideDock"
        case builtinKeepAwake = "builtin.keepAwake"
        case builtinKeyboardLock = "builtin.keyboardLock"
        case builtinLockScreen = "builtin.lockScreen"
        case builtinMuteAudio = "builtin.muteAudio"
        case builtinOCR = "builtin.ocr"
        case builtinPickColor = "builtin.pickColor"
        case builtinPortManager = "builtin.portManager"
        case builtinQRCode = "builtin.qrcode"
        case builtinRestartDock = "builtin.restartDock"
        case builtinRestartFinder = "builtin.restartFinder"
        case builtinRestartMenuBar = "builtin.restartMenuBar"
        case builtinScreenshot = "builtin.screenshot"
        case builtinShowHiddenFiles = "builtin.showHiddenFiles"
        case builtinSystemSleep = "builtin.systemSleep"
        case demoHello = "demo.hello"
        case menubarIconAppConnected = "menubarIcon.appConnected"
        case menubarIconBolt = "menubarIcon.bolt"
        case menubarIconCommand = "menubarIcon.command"
        case menubarIconConnectedPoints = "menubarIcon.connectedPoints"
        case menubarIconCycle = "menubarIcon.cycle"
        case menubarIconDoorLeft = "menubarIcon.doorLeft"
        case menubarIconGlobe = "menubarIcon.globe"
        case menubarIconGrid2x2 = "menubarIcon.grid2x2"
        case menubarIconGrid3x3 = "menubarIcon.grid3x3"
        case menubarIconLink = "menubarIcon.link"
        case menubarIconNetwork = "menubarIcon.network"
        case menubarIconSparkles = "menubarIcon.sparkles"
        case menubarIconSwitch = "menubarIcon.switch"
        case menubarIconWand = "menubarIcon.wand"
        // Migration tasks append cases here. Keep alphabetical by raw value.
    }
}

/// Resolves a translation for `key` against the active `LocalizationManager`.
/// Use this for non-View strings (NSAlert messages, .help / .accessibilityLabel
/// modifiers, string interpolation). For Text-in-views prefer `LocalizedText`
/// so the view re-renders when the preference changes.
@MainActor
func L(_ key: L10n.Key, _ args: CVarArg...) -> String {
    let manager = LocalizationManager.shared
    let template = NSLocalizedString(
        key.rawValue,
        tableName: nil,
        bundle: manager.bundle,
        value: key.rawValue,
        comment: ""
    )
    if args.isEmpty {
        return template
    }
    return String(format: template, locale: manager.effectiveLocale, arguments: args)
}

/// SwiftUI Text wrapper that re-renders on `LocalizationManager` changes.
/// Replaces raw `Text("中文")` everywhere in the view tree.
@MainActor
struct LocalizedText: View {
    @Environment(LocalizationManager.self) private var manager
    let key: L10n.Key

    init(_ key: L10n.Key) {
        self.key = key
    }

    var body: some View {
        // Reading manager.preference establishes a dependency so SwiftUI
        // re-renders this view when the user changes language.
        _ = manager.preference
        return Text(L(key))
    }
}
