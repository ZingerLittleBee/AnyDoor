import Foundation

/// Code-defined catalog of all built-in panel items. The set of cases is the product spec;
/// users cannot add new built-ins, only customize visibility / order / hotkey via BuiltinPreference.
enum BuiltinItem: String, CaseIterable, Sendable {
    case appShortcuts
    case keepAwake
    case muteAudio
    case microphoneMute
    case hideDesktopIcons
    case showHiddenFiles
    case darkMode
    case lockScreen
    case emptyTrash
    case screenshot
    case captureWindow
    case captureFullscreen
    case captureTimer
    case captureModeBar
    case recordScreen
    case clearClipboard
    case ocr
    case pickColor
    case clipboardWall
    case clipboardMonitoring
    case displaySleep
    case systemSleep
    case scheduledShutdown
    case hideDock
    case autoHideMenuBar
    case restartFinder
    case restartDock
    case restartMenuBar
    case flushDNS
    case keyboardLock
    case portManager
    case qrcode
    case brightness
    case brightnessUp
    case brightnessDown
    case windowLeftHalf
    case windowRightHalf
    case windowMaximize
    case windowCenter
    case windowTopHalf
    case windowBottomHalf
    case windowTopLeftQuarter
    case windowTopRightQuarter
    case windowBottomLeftQuarter
    case windowBottomRightQuarter
    case windowLeftThird
    case windowCenterThird
    case windowRightThird
    case windowLeftTwoThirds
    case windowRightTwoThirds
    case windowMoveNextDisplay
    case windowMovePreviousDisplay
    case windowLayout
    case hostsManager

    enum Kind: Sendable {
        case toggle
        case action
        case submenu
        case brightnessControl
        case hiddenHotkey
    }

    var kind: Kind {
        switch self {
        case .appShortcuts, .portManager, .windowLayout, .hostsManager: return .submenu
        case .keepAwake, .muteAudio, .microphoneMute, .hideDesktopIcons, .showHiddenFiles, .darkMode,
             .hideDock, .autoHideMenuBar, .keyboardLock, .scheduledShutdown: return .toggle
        case .clipboardMonitoring: return .toggle
        case .lockScreen, .emptyTrash, .screenshot, .clearClipboard, .ocr, .qrcode, .pickColor, .displaySleep, .systemSleep,
             .restartFinder, .restartDock, .restartMenuBar, .flushDNS, .clipboardWall,
             .windowLeftHalf, .windowRightHalf, .windowMaximize, .windowCenter,
             .windowTopHalf, .windowBottomHalf,
             .windowTopLeftQuarter, .windowTopRightQuarter,
             .windowBottomLeftQuarter, .windowBottomRightQuarter,
             .windowLeftThird, .windowCenterThird, .windowRightThird,
             .windowLeftTwoThirds, .windowRightTwoThirds,
             .windowMoveNextDisplay, .windowMovePreviousDisplay,
             .captureWindow, .captureFullscreen, .captureTimer, .captureModeBar, .recordScreen: return .action
        case .brightness: return .brightnessControl
        case .brightnessUp, .brightnessDown: return .hiddenHotkey
        }
    }

    var titleKey: L10n.Key {
        switch self {
        case .appShortcuts:      return .builtinAppShortcuts
        case .keepAwake:         return .builtinKeepAwake
        case .muteAudio:         return .builtinMuteAudio
        case .microphoneMute:    return .builtinMicrophoneMute
        case .hideDesktopIcons:  return .builtinHideDesktopIcons
        case .showHiddenFiles:   return .builtinShowHiddenFiles
        case .darkMode:          return .builtinDarkMode
        case .lockScreen:        return .builtinLockScreen
        case .emptyTrash:        return .builtinEmptyTrash
        case .screenshot:        return .builtinScreenshot
        case .captureWindow:     return .builtinCaptureWindow
        case .captureFullscreen: return .builtinCaptureFullscreen
        case .captureTimer:      return .builtinCaptureTimer
        case .captureModeBar:    return .builtinCaptureModeBar
        case .recordScreen:      return .builtinRecordScreen
        case .clearClipboard:    return .builtinClearClipboard
        case .ocr:               return .builtinOCR
        case .pickColor:         return .builtinPickColor
        case .clipboardWall:     return .builtinClipboardWall
        case .clipboardMonitoring: return .builtinClipboardMonitoring
        case .displaySleep:      return .builtinDisplaySleep
        case .systemSleep:       return .builtinSystemSleep
        case .scheduledShutdown: return .builtinScheduledShutdown
        case .hideDock:          return .builtinHideDock
        case .autoHideMenuBar:   return .builtinAutoHideMenuBar
        case .restartFinder:     return .builtinRestartFinder
        case .restartDock:       return .builtinRestartDock
        case .restartMenuBar:    return .builtinRestartMenuBar
        case .flushDNS:          return .builtinFlushDNS
        case .keyboardLock:      return .builtinKeyboardLock
        case .portManager:       return .builtinPortManager
        case .qrcode:            return .builtinQRCode
        case .brightness:        return .builtinBrightness
        case .brightnessUp:      return .builtinBrightnessUp
        case .brightnessDown:    return .builtinBrightnessDown
        case .windowLeftHalf:    return .builtinWindowLeftHalf
        case .windowRightHalf:   return .builtinWindowRightHalf
        case .windowMaximize:    return .builtinWindowMaximize
        case .windowCenter:      return .builtinWindowCenter
        case .windowTopHalf:            return .builtinWindowTopHalf
        case .windowBottomHalf:         return .builtinWindowBottomHalf
        case .windowTopLeftQuarter:     return .builtinWindowTopLeftQuarter
        case .windowTopRightQuarter:    return .builtinWindowTopRightQuarter
        case .windowBottomLeftQuarter:  return .builtinWindowBottomLeftQuarter
        case .windowBottomRightQuarter: return .builtinWindowBottomRightQuarter
        case .windowLeftThird:          return .builtinWindowLeftThird
        case .windowCenterThird:        return .builtinWindowCenterThird
        case .windowRightThird:         return .builtinWindowRightThird
        case .windowLeftTwoThirds:      return .builtinWindowLeftTwoThirds
        case .windowRightTwoThirds:     return .builtinWindowRightTwoThirds
        case .windowMoveNextDisplay:    return .builtinWindowMoveNextDisplay
        case .windowMovePreviousDisplay: return .builtinWindowMovePreviousDisplay
        case .windowLayout:      return .builtinWindowLayout
        case .hostsManager:      return .builtinHostsManager
        }
    }

    var symbol: String {
        switch self {
        case .appShortcuts: return "keyboard"
        case .keepAwake: return "cup.and.saucer.fill"
        case .muteAudio: return "speaker.slash.fill"
        case .microphoneMute: return "mic.slash.fill"
        case .hideDesktopIcons: return "rectangle.on.rectangle.slash"
        case .showHiddenFiles: return "eye.fill"
        case .darkMode: return "moon.fill"
        case .lockScreen: return "lock.fill"
        case .emptyTrash: return "trash.fill"
        case .screenshot: return "camera.viewfinder"
        case .captureWindow:     return "macwindow"
        case .captureFullscreen: return "rectangle.dashed"
        case .captureTimer:      return "timer"
        case .captureModeBar:    return "camera.on.rectangle"
        case .recordScreen:      return "record.circle"
        case .clearClipboard: return "clipboard"
        case .ocr: return "text.viewfinder"
        case .pickColor: return "eyedropper"
        case .clipboardWall: return "doc.on.clipboard"
        case .clipboardMonitoring: return "clipboard.fill"
        case .displaySleep: return "moon.zzz.fill"
        case .systemSleep: return "powersleep"
        case .scheduledShutdown: return "power"
        case .hideDock: return "dock.rectangle"
        case .autoHideMenuBar: return "menubar.rectangle"
        case .restartFinder: return "macwindow.on.rectangle"
        case .restartDock: return "dock.arrow.down.rectangle"
        case .restartMenuBar: return "menubar.arrow.up.rectangle"
        case .flushDNS: return "network"
        case .keyboardLock: return "keyboard.fill"
        case .portManager: return "network"
        case .qrcode: return "qrcode.viewfinder"
        case .brightness: return "sun.max"
        case .brightnessUp: return "sun.max"
        case .brightnessDown: return "sun.min"
        case .windowLeftHalf: return "rectangle.lefthalf.filled"
        case .windowRightHalf: return "rectangle.righthalf.filled"
        case .windowMaximize: return "arrow.up.left.and.arrow.down.right"
        case .windowCenter: return "rectangle.center.inset.filled"
        case .windowTopHalf: return "rectangle.tophalf.filled"
        case .windowBottomHalf: return "rectangle.bottomhalf.filled"
        case .windowTopLeftQuarter: return "square.split.2x2"
        case .windowTopRightQuarter: return "square.split.2x2"
        case .windowBottomLeftQuarter: return "square.split.2x2"
        case .windowBottomRightQuarter: return "square.split.2x2"
        case .windowLeftThird: return "rectangle.split.3x1"
        case .windowCenterThird: return "rectangle.split.3x1"
        case .windowRightThird: return "rectangle.split.3x1"
        case .windowLeftTwoThirds: return "rectangle.split.3x1"
        case .windowRightTwoThirds: return "rectangle.split.3x1"
        case .windowMoveNextDisplay: return "rectangle.on.rectangle"
        case .windowMovePreviousDisplay: return "rectangle.on.rectangle"
        case .windowLayout: return "macwindow"
        case .hostsManager: return "list.bullet.rectangle"
        }
    }

    /// Initial sort weight when seeding. After seeding, users may reorder freely.
    var defaultOrder: Double {
        switch self {
        case .keepAwake: return 100
        case .appShortcuts: return 200
        case .muteAudio: return 300
        case .microphoneMute: return 310
        case .hideDesktopIcons: return 400
        case .showHiddenFiles: return 500
        case .darkMode: return 600
        case .lockScreen: return 700
        case .emptyTrash: return 800
        case .screenshot: return 900
        case .captureWindow:     return 905
        case .captureFullscreen: return 910
        case .captureTimer:      return 915
        case .captureModeBar:    return 920
        case .recordScreen:      return 925
        case .clearClipboard: return 940
        case .ocr: return 950
        case .pickColor: return 975
        case .clipboardWall: return 250
        case .clipboardMonitoring: return 260
        case .displaySleep: return 1000
        case .systemSleep: return 1100
        case .scheduledShutdown: return 1150
        case .hideDock: return 1200
        case .autoHideMenuBar: return 1300
        case .restartFinder: return 1400
        case .restartDock: return 1500
        case .restartMenuBar: return 1600
        case .flushDNS: return 1700
        case .keyboardLock: return 1800
        case .portManager: return 1900
        case .qrcode: return 960
        case .brightness: return 650
        case .brightnessUp: return 999_998
        case .brightnessDown: return 999_999
        case .windowLeftHalf:           return 2010
        case .windowRightHalf:          return 2020
        case .windowTopHalf:            return 2030
        case .windowBottomHalf:         return 2040
        case .windowTopLeftQuarter:     return 2050
        case .windowTopRightQuarter:    return 2060
        case .windowBottomLeftQuarter:  return 2070
        case .windowBottomRightQuarter: return 2080
        case .windowLeftThird:          return 2110
        case .windowCenterThird:        return 2120
        case .windowRightThird:         return 2130
        case .windowLeftTwoThirds:      return 2140
        case .windowRightTwoThirds:     return 2150
        case .windowMaximize:           return 2160
        case .windowCenter:             return 2170
        case .windowMoveNextDisplay:    return 2180
        case .windowMovePreviousDisplay: return 2190
        case .windowLayout:    return 2000
        case .hostsManager:    return 1950
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
        case .captureWindow, .captureFullscreen, .captureTimer: return .screenshot
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

    /// Whether this item should default to being shown in the menu bar panel when first seeded.
    /// False only for hidden-hotkey items (brightness ± live on the brightness row only).
    var defaultVisibility: Bool {
        switch self.kind {
        case .toggle, .action, .submenu, .brightnessControl: return true
        case .hiddenHotkey:                                   return false
        }
    }
}
