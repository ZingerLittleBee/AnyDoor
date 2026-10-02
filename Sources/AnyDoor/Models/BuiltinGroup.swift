import Foundation
import PluginInterface

/// Single source of truth for how built-in commands are grouped into themed
/// command palette sections (`CommandPaletteWindowController`). A
/// `BuiltinItem` claimed by no themed group lands in the palette's general
/// Commands section, which is listed first.
enum BuiltinGroup: String, CaseIterable, Sendable, Hashable {
    case togglesAppearance
    case powerSession
    case screenshot
    case translation

    /// Themed groups in command palette display order.
    static let themedDefaultOrder: [BuiltinGroup] = [
        .togglesAppearance, .powerSession, .screenshot, .translation,
    ]

    /// Command palette section header title.
    var titleKey: L10n.Key {
        switch self {
        case .togglesAppearance: return .commandPaletteSectionToggles
        case .powerSession:      return .commandPaletteSectionPower
        case .screenshot:        return .commandPaletteSectionCapture
        case .translation:       return .commandPaletteSectionTranslation
        }
    }

    /// Explicit members of each themed group. Mirrors the command palette's
    /// prior hardcoded sets exactly (regression-guarded in BuiltinGroupTests).
    var members: Set<BuiltinItem> {
        switch self {
        case .togglesAppearance:
            return [.muteAudio, .microphoneMute, .darkMode, .hideDock, .autoHideMenuBar,
                    .hideDesktopIcons, .showHiddenFiles, .keyboardLock, .brightness]
        case .powerSession:
            return [.lockScreen, .displaySleep, .systemSleep, .scheduledShutdown, .keepAwake]
        case .screenshot:
            return [.screenshot, .captureWindow, .captureFullscreen, .captureTimer,
                    .captureModeBar, .recordScreen, .captureScrolling]
        case .translation:
            return [.translate, .screenshotTranslate, .translateSelection]
        }
    }
}
