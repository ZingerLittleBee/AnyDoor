import PluginInterface

/// Core-side presentation and integration of the shared command catalog.
///
/// `BuiltinItem` itself lives in the lean `PluginInterface` target
/// (ADR-0006); members that pull in app subsystems — the L10n string catalog,
/// clipboard-history kinds, AppKit sound playback — stay here so the
/// interface target never depends on them.
extension BuiltinItem {
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
        case .captureScrolling:  return .builtinCaptureScrolling
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
        case .bluetoothBattery:  return .builtinBluetoothBattery
        case .translate:           return .builtinTranslate
        case .screenshotTranslate: return .builtinScreenshotTranslate
        case .translateSelection:  return .builtinTranslateSelection
        case .imageConversion:     return .builtinImageConversion
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
