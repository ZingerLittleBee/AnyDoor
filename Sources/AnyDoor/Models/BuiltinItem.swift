import Foundation

/// Code-defined catalog of all built-in panel items. The set of cases is the product spec;
/// users cannot add new built-ins, only customize visibility / order / hotkey via BuiltinPreference.
enum BuiltinItem: String, CaseIterable, Sendable {
    case appShortcuts
    case keepAwake
    case muteAudio
    case hideDesktopIcons
    case showHiddenFiles
    case darkMode
    case lockScreen
    case emptyTrash
    case screenshot
    case ocr
    case pickColor
    case displaySleep
    case systemSleep
    case hideDock
    case autoHideMenuBar
    case restartFinder
    case restartDock
    case restartMenuBar
    case flushDNS
    case keyboardLock
    case portManager
    case qrcode

    enum Kind: Sendable {
        case toggle
        case action
        case submenu
    }

    var kind: Kind {
        switch self {
        case .appShortcuts, .portManager: return .submenu
        case .keepAwake, .muteAudio, .hideDesktopIcons, .showHiddenFiles, .darkMode,
             .hideDock, .autoHideMenuBar, .keyboardLock: return .toggle
        case .lockScreen, .emptyTrash, .screenshot, .ocr, .qrcode, .pickColor, .displaySleep, .systemSleep,
             .restartFinder, .restartDock, .restartMenuBar, .flushDNS: return .action
        }
    }

    var titleKey: L10n.Key {
        switch self {
        case .appShortcuts:      return .builtinAppShortcuts
        case .keepAwake:         return .builtinKeepAwake
        case .muteAudio:         return .builtinMuteAudio
        case .hideDesktopIcons:  return .builtinHideDesktopIcons
        case .showHiddenFiles:   return .builtinShowHiddenFiles
        case .darkMode:          return .builtinDarkMode
        case .lockScreen:        return .builtinLockScreen
        case .emptyTrash:        return .builtinEmptyTrash
        case .screenshot:        return .builtinScreenshot
        case .ocr:               return .builtinOCR
        case .pickColor:         return .builtinPickColor
        case .displaySleep:      return .builtinDisplaySleep
        case .systemSleep:       return .builtinSystemSleep
        case .hideDock:          return .builtinHideDock
        case .autoHideMenuBar:   return .builtinAutoHideMenuBar
        case .restartFinder:     return .builtinRestartFinder
        case .restartDock:       return .builtinRestartDock
        case .restartMenuBar:    return .builtinRestartMenuBar
        case .flushDNS:          return .builtinFlushDNS
        case .keyboardLock:      return .builtinKeyboardLock
        case .portManager:       return .builtinPortManager
        case .qrcode:            return .builtinQRCode
        }
    }

    var symbol: String {
        switch self {
        case .appShortcuts: return "keyboard"
        case .keepAwake: return "cup.and.saucer.fill"
        case .muteAudio: return "speaker.slash.fill"
        case .hideDesktopIcons: return "rectangle.on.rectangle.slash"
        case .showHiddenFiles: return "eye.fill"
        case .darkMode: return "moon.fill"
        case .lockScreen: return "lock.fill"
        case .emptyTrash: return "trash.fill"
        case .screenshot: return "camera.viewfinder"
        case .ocr: return "text.viewfinder"
        case .pickColor: return "eyedropper"
        case .displaySleep: return "moon.zzz.fill"
        case .systemSleep: return "powersleep"
        case .hideDock: return "dock.rectangle"
        case .autoHideMenuBar: return "menubar.rectangle"
        case .restartFinder: return "macwindow.on.rectangle"
        case .restartDock: return "dock.arrow.down.rectangle"
        case .restartMenuBar: return "menubar.arrow.up.rectangle"
        case .flushDNS: return "network"
        case .keyboardLock: return "keyboard.fill"
        case .portManager: return "network"
        case .qrcode: return "qrcode.viewfinder"
        }
    }

    /// Initial sort weight when seeding. After seeding, users may reorder freely.
    var defaultOrder: Double {
        switch self {
        case .keepAwake: return 100
        case .appShortcuts: return 200
        case .muteAudio: return 300
        case .hideDesktopIcons: return 400
        case .showHiddenFiles: return 500
        case .darkMode: return 600
        case .lockScreen: return 700
        case .emptyTrash: return 800
        case .screenshot: return 900
        case .ocr: return 950
        case .pickColor: return 975
        case .displaySleep: return 1000
        case .systemSleep: return 1100
        case .hideDock: return 1200
        case .autoHideMenuBar: return 1300
        case .restartFinder: return 1400
        case .restartDock: return 1500
        case .restartMenuBar: return 1600
        case .flushDNS: return 1700
        case .keyboardLock: return 1800
        case .portManager: return 1900
        case .qrcode: return 960
        }
    }

    /// The clipboard history bucket this built-in writes into, if any.
    /// Non-history items (toggles, submenus, system actions) return nil.
    var historyKind: ClipboardHistoryKind? {
        switch self {
        case .ocr: return .ocr
        case .pickColor: return .color
        case .qrcode: return .qrcode
        case .screenshot: return .screenshot
        default: return nil
        }
    }

    /// True if the item requires macOS Automation permission (NSAppleEventsUsage).
    var requiresAutomation: Bool {
        switch self {
        case .darkMode, .emptyTrash: return true
        default: return false
        }
    }

    /// Optional auditory feedback played the moment the user activates this item.
    /// Lock screen is intentionally silent: macOS transitions to the login window
    /// immediately and the system already provides its own auditory transition.
    var feedbackSound: SystemSound? {
        switch self {
        case .emptyTrash: return .emptyTrash
        default: return nil
        }
    }
}
