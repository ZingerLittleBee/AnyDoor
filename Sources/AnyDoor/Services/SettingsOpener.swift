import AppKit
import SwiftUI

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
final class SettingsOpener {
    static let shared = SettingsOpener()
    var open: (() -> Void)?

    func tryOpen() {
        NSApp.activate(ignoringOtherApps: true)
        if let open {
            open()
            return
        }
        // Fallback for the (rare) case the capture view hasn't appeared yet.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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
