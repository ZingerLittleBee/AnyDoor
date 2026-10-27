import AppKit
import Observation
import SwiftUI

/// Stable identifiers for the Settings sidebar panes, so callers can deep-link
/// to a specific pane (e.g. the translation gear button) instead of landing on
/// whatever pane was last open.
enum SettingsTab: String, Hashable, CaseIterable {
    case panel
    case quicklinks
    case clipboard
    case capture
    case translation
    case plugins
    case sync
    case general
}

/// Single entry point for opening the Settings window from any code path
/// (status item context menu, dock reopen handler, deep links, ⌘,).
///
/// The window is a manually managed NSWindow owned by
/// `SettingsWindowController` — not a SwiftUI `Settings` scene — so opening it
/// is a direct call; no `\.openSettings` capture is needed. This type remains
/// the deep-link surface: `desiredTab` carries the pane a caller wants
/// selected, observed by `SettingsView`.
@MainActor
@Observable
final class SettingsOpener {
    static let shared = SettingsOpener()

    /// Presents the Settings window. Injectable so tests can observe an open
    /// request without creating a real window.
    @ObservationIgnored var open: @MainActor () -> Void = {
        SettingsWindowController.shared.show()
    }

    /// The tab `SettingsView` should select. `nil` leaves the last-open tab.
    /// Observed by `SettingsView`'s sidebar selection binding.
    var desiredTab: SettingsTab?

    /// An app shortcut whose hotkey recorder should start recording once the
    /// Panel pane shows it. The recorder clears this when it starts.
    var pendingAppShortcutRecording: UUID?

    func tryOpen() {
        open()
    }

    /// Open Settings and deep-link to `tab`.
    func tryOpen(tab: SettingsTab) {
        desiredTab = tab
        tryOpen()
    }

    /// Open the Panel pane and start recording the hotkey of app shortcut `id`.
    func tryOpenRecordingHotkey(forAppShortcut id: UUID) {
        pendingAppShortcutRecording = id
        tryOpen(tab: .panel)
    }
}
