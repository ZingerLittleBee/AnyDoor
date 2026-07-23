import Foundation

/// Code-defined catalog of all built-in panel items. The set of cases is the product spec;
/// users cannot add new built-ins, only customize visibility / order / hotkey via BuiltinPreference.
///
/// The catalog is closed and shared (ADR-0006): a Native Plugin does not mint
/// its own command identities — it Claims cases of this enum, and every case
/// is owned by exactly one Native Plugin or by the Core.
public enum BuiltinItem: String, CaseIterable, Sendable {
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
    case captureScrolling
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
    case bluetoothBattery
    case translate
    case screenshotTranslate
    case translateSelection
    case imageConversion

    public enum Kind: Sendable {
        case toggle
        case action
        case submenu
        case brightnessControl
        case hiddenHotkey
    }

    public var kind: Kind {
        switch self {
        case .appShortcuts, .portManager, .windowLayout, .hostsManager, .bluetoothBattery: return .submenu
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
             .captureWindow, .captureFullscreen, .captureTimer, .captureModeBar, .recordScreen,
             .captureScrolling,
             .translate, .screenshotTranslate, .translateSelection,
             .imageConversion: return .action
        case .brightness: return .brightnessControl
        case .brightnessUp, .brightnessDown: return .hiddenHotkey
        }
    }

    public var symbol: String {
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
        case .captureScrolling:  return "arrow.down.to.line"
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
        case .bluetoothBattery: return "battery.100"
        case .translate: return "character.bubble"
        case .screenshotTranslate: return "text.viewfinder"
        case .translateSelection: return "text.cursor"
        case .imageConversion: return "photo.on.rectangle"
        }
    }

    /// Initial sort weight when seeding. After seeding, users may reorder freely.
    public var defaultOrder: Double {
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
        case .captureScrolling:  return 930
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
        case .bluetoothBattery: return 1980
        case .translate: return 980
        case .screenshotTranslate: return 982
        case .translateSelection: return 984
        case .imageConversion: return 986
        }
    }

    /// True if the item requires macOS Automation permission (NSAppleEventsUsage).
    public var requiresAutomation: Bool {
        switch self {
        case .darkMode, .emptyTrash: return true
        default: return false
        }
    }

    /// Whether this item should default to being shown in the menu bar panel when first seeded.
    /// False only for hidden-hotkey items (brightness ± live on the brightness row only).
    public var defaultVisibility: Bool {
        switch self.kind {
        case .toggle, .action, .submenu, .brightnessControl: return true
        case .hiddenHotkey:                                   return false
        }
    }
}
