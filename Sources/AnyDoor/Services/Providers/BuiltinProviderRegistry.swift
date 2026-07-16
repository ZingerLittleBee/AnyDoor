import Foundation
import PluginInterface

/// Builds the Core's production provider set — one provider per actionable
/// (toggle/action-kind) `BuiltinItem` the Core claims. Plugin-claimed commands
/// (e.g. Image Conversion) contribute their providers through their
/// `NativePlugin.providers` instead.
///
/// Extracted from AppDelegate so tests can assert catalog coverage: a new
/// BuiltinItem case registered here with the wrong protocol, or not registered
/// at all, is caught by `BuiltinCatalogInvariantTests` instead of silently
/// doing nothing when its panel row or hotkey fires (`PanelStore.toggle/run`
/// guard-return when no matching provider exists).
@MainActor
enum BuiltinProviderRegistry {
    static func makeAll(
        onKeepAwakeChange: @escaping @MainActor @Sendable (KeepAwakeState) -> Void
    ) -> [any BuiltinProvider] {
        [
            KeepAwakeProvider(onChange: onKeepAwakeChange),
            HideDesktopIconsProvider(),
            ShowHiddenFilesProvider(),
            MuteAudioProvider(),
            MicrophoneMuteProvider(),
            DarkModeProvider(),
            LockScreenProvider(),
            EmptyTrashProvider(),
            CaptureRegionProvider(),
            CaptureWindowProvider(),
            CaptureFullscreenProvider(),
            CaptureTimerProvider(),
            CaptureModeBarProvider(),
            RecordScreenProvider(),
            CaptureScrollingProvider(),
            ClearClipboardProvider(),
            DisplaySleepProvider(),
            SystemSleepProvider(),
            ScheduledShutdownProvider(),
            HideDockProvider(),
            AutoHideMenuBarProvider(),
            RestartFinderProvider(),
            RestartDockProvider(),
            RestartMenuBarProvider(),
            FlushDNSProvider(),
            KeyboardLockProvider(),
            OCRProvider(),
            QRCodeProvider(),
            PickColorProvider(),
            ClipboardMonitoringProvider(),
            WindowLayoutProvider(item: .windowLeftHalf, action: .leftHalf),
            WindowLayoutProvider(item: .windowRightHalf, action: .rightHalf),
            WindowLayoutProvider(item: .windowMaximize, action: .maximize),
            WindowLayoutProvider(item: .windowCenter, action: .center),
            WindowLayoutProvider(item: .windowTopHalf, action: .topHalf),
            WindowLayoutProvider(item: .windowBottomHalf, action: .bottomHalf),
            WindowLayoutProvider(item: .windowTopLeftQuarter, action: .topLeftQuarter),
            WindowLayoutProvider(item: .windowTopRightQuarter, action: .topRightQuarter),
            WindowLayoutProvider(item: .windowBottomLeftQuarter, action: .bottomLeftQuarter),
            WindowLayoutProvider(item: .windowBottomRightQuarter, action: .bottomRightQuarter),
            WindowLayoutProvider(item: .windowLeftThird, action: .leftThird),
            WindowLayoutProvider(item: .windowCenterThird, action: .centerThird),
            WindowLayoutProvider(item: .windowRightThird, action: .rightThird),
            WindowLayoutProvider(item: .windowLeftTwoThirds, action: .leftTwoThirds),
            WindowLayoutProvider(item: .windowRightTwoThirds, action: .rightTwoThirds),
            WindowLayoutProvider(item: .windowMoveNextDisplay, action: .moveToNextDisplay),
            WindowLayoutProvider(item: .windowMovePreviousDisplay, action: .moveToPreviousDisplay),
            ClipboardWallProvider(),
            TranslateProvider(),
            ScreenshotTranslateProvider(),
            TranslateSelectionProvider(),
        ]
    }
}
