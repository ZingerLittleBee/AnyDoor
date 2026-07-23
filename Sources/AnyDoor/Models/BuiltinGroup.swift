import Foundation
import PluginInterface

/// Single source of truth for how built-in commands are grouped into themed
/// sections. Shared by the command palette (`CommandPaletteWindowController`)
/// and the Panel settings page. `.general` is the implicit, headerless,
/// always-first bucket: every `BuiltinItem` not claimed by a themed group.
enum BuiltinGroup: String, CaseIterable, Sendable, Hashable {
    case general
    case togglesAppearance
    case powerSession
    case screenshot
    case translation

    /// Themed groups in default display order. `.general` is intentionally
    /// excluded — it is the implicit first bucket and is never reordered.
    static let themedDefaultOrder: [BuiltinGroup] = [
        .togglesAppearance, .powerSession, .screenshot, .translation,
    ]

    /// Section header title, or `nil` for `.general` (rendered without a header).
    var titleKey: L10n.Key? {
        switch self {
        case .general:           return nil
        case .togglesAppearance: return .commandPaletteSectionToggles
        case .powerSession:      return .commandPaletteSectionPower
        case .screenshot:        return .commandPaletteSectionCapture
        case .translation:       return .commandPaletteSectionTranslation
        }
    }

    /// Explicit members of each themed group. Mirrors the command palette's
    /// prior hardcoded sets exactly (regression-guarded in BuiltinGroupTests).
    /// `.general` has no explicit list — it is "the rest".
    var members: Set<BuiltinItem> {
        switch self {
        case .general:
            return []
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

    /// The owning group of an item: the first themed group that claims it, else
    /// `.general`.
    static func group(for item: BuiltinItem) -> BuiltinGroup {
        for group in themedDefaultOrder where group.members.contains(item) {
            return group
        }
        return .general
    }
}
