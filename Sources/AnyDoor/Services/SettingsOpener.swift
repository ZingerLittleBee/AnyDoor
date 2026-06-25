import AppKit
import Observation
import SwiftUI

/// Stable identifiers for the Settings `TabView` tabs, so callers can deep-link
/// to a specific tab (e.g. the translation gear button) instead of landing on
/// whatever tab was last open.
enum SettingsTab: String, Hashable {
    case panel
    case clipboard
    case capture
    case translation
    case general
}

/// Bridges SwiftUI's `\.openSettings` environment action into AppKit code paths
/// (status item context menu, dock reopen handler, etc.).
///
/// `\.openSettings` is only resolvable from inside a SwiftUI view in an app that
/// declares a `Settings` scene; sending `showSettingsWindow:` through the
/// responder chain from an `NSMenu` action does not reach the SwiftUI-injected
/// target. `AppDelegate` mounts an off-screen `NSHostingView` containing
/// `SettingsOpenerCaptureView` once at launch, which records the action closure
/// here on first appearance.
@MainActor
@Observable
final class SettingsOpener {
    static let shared = SettingsOpener()
    @ObservationIgnored var open: (() -> Void)?

    /// The tab `SettingsView` should select. `nil` leaves the last-open tab.
    /// Observed by `SettingsView`'s `TabView` selection binding.
    var desiredTab: SettingsTab?

    func tryOpen() {
        NSApp.activate(ignoringOtherApps: true)
        if let open {
            open()
            return
        }
        // Fallback for the (rare) case the capture view hasn't appeared yet.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Open Settings and deep-link to `tab`.
    func tryOpen(tab: SettingsTab) {
        desiredTab = tab
        tryOpen()
    }
}

struct SettingsOpenerCaptureView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                SettingsOpener.shared.open = { openSettings() }
            }
    }
}
