import AppKit
import Foundation
import PluginInterface

/// Toggle macOS dark mode via AppleScript to System Events.
///
/// The state comes from AppKit rather than System Events: AnyDoor never
/// overrides its app appearance, so `NSApplication.effectiveAppearance` is the
/// system's (Auto included), and reading it sends no Apple Event. A panel or
/// palette refresh therefore never asks System Events for the state; only
/// `setState` scripts it, which needs Automation permission for System Events.
/// On first use the system prompts; a denial (errorNumber -1743) reports
/// `.denied`.
actor DarkModeProvider: ToggleProvider {
    let itemKey: BuiltinItem = .darkMode

    /// System Events' Automation verdict, shared with the Settings and
    /// onboarding permission rows (`AutomationPermission.systemEvents`).
    private let automation: AutomationPermissionCheck

    /// Whether the system appearance is dark. Injected so tests don't depend on
    /// the Mac's appearance.
    private let isDarkAppearance: @Sendable () async -> Bool

    /// Runs `setState`'s AppleScript. Injected so tests never send an Apple
    /// Event.
    private let runScript: @Sendable (String) async throws -> String

    /// `automation` has no default, so a test can't reach the real System
    /// Events check by accident.
    init(
        automation: AutomationPermissionCheck,
        isDarkAppearance: @escaping @Sendable () async -> Bool = {
            await MainActor.run {
                NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
        },
        runScript: @escaping @Sendable (String) async throws -> String = AppleScriptRunner.run
    ) {
        self.automation = automation
        self.isDarkAppearance = isDarkAppearance
        self.runScript = runScript
    }

    /// Checked live, so a grant made in System Settings clears the row's
    /// "needs permission" state on the next panel or palette open. A denied
    /// panel row only opens System Settings and never toggles, so without a
    /// live check it would stay denied until a hotkey or palette toggle
    /// happened to succeed. Waits at most a second for System Events, and then
    /// reports the last verdict.
    var permission: PermissionStatus {
        get async { await automation.status }
    }

    func readState() async -> Bool {
        await isDarkAppearance()
    }

    func setState(_ dark: Bool) async throws {
        do {
            _ = try await runScript("""
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to \(dark)
                    end tell
                end tell
            """)
            await automation.record(.granted)
        } catch BuiltinError.missingAutomationPermission {
            await automation.record(.denied)
            throw BuiltinError.missingAutomationPermission
        }
    }
}
