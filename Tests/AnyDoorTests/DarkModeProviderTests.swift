import CoreServices
import Foundation
import os
import PluginInterface
import XCTest
@testable import AnyDoor

/// Dark Mode reads its state from the appearance and its permission from the
/// shared System Events check. System Events, its Automation verdict, and the
/// appearance are all scripted, so no test reaches TCC, sends an Apple Event,
/// or depends on the Mac's appearance.
final class DarkModeProviderTests: XCTestCase {

    /// Reading the state never asks System Events, so neither a toggle's state
    /// read nor a panel or palette refresh waits for one that stopped answering.
    func testStateFollowsTheAppearanceWhileSystemEventsHangs() async throws {
        let systemEvents = ScriptedAutomationCheck(noErr)
        addTeardownBlock { systemEvents.release(answering: noErr) }
        let isDark = OSAllocatedUnfairLock(initialState: true)
        let scripts = OSAllocatedUnfairLock(initialState: 0)
        let provider = DarkModeProvider(
            automation: systemEventsCheck(systemEvents),
            isDarkAppearance: { isDark.withLock { $0 } },
            runScript: { _ in
                scripts.withLock { $0 += 1 }
                return ""
            }
        )
        systemEvents.stall()

        var isDarkState = try await bounded(within: 5) { await provider.readState() }
        XCTAssertTrue(isDarkState)

        isDark.withLock { $0 = false }
        isDarkState = try await bounded(within: 5) { await provider.readState() }
        XCTAssertFalse(isDarkState, "the next read follows the appearance")

        XCTAssertEqual(systemEvents.entries, 0, "reading the state never checks System Events")
        XCTAssertEqual(scripts.withLock { $0 }, 0, "reading the state sends no Apple Event")
    }

    func testPermissionFollowsTheLiveSystemEventsVerdict() async throws {
        let systemEvents = ScriptedAutomationCheck(errAEEventNotPermitted)
        let provider = DarkModeProvider(
            automation: systemEventsCheck(systemEvents),
            isDarkAppearance: { false },
            runScript: { _ in "" }
        )

        var permission = try await boundedPermission(of: provider)
        XCTAssertEqual(permission, .denied)

        // Granted in System Settings: the next read reports it, no toggle needed.
        systemEvents.set(noErr)
        permission = try await boundedPermission(of: provider)
        XCTAssertEqual(permission, .granted)

        // Undecided again (a TCC reset): runnable, so a click shows the system
        // prompt instead of sending the user to System Settings.
        systemEvents.set(errAEEventWouldRequireUserConsent)
        permission = try await boundedPermission(of: provider)
        XCTAssertEqual(permission, .undetermined)
    }

    /// A denied row only opens System Settings and never toggles, so the grant
    /// has to show up on the next panel open by itself, even after System
    /// Events quit while idle.
    @MainActor
    func testDeniedRowRecoversOnTheNextRefreshAfterTheGrant() async throws {
        let systemEvents = ScriptedAutomationCheck(errAEEventNotPermitted, isRunning: false)
        let store = try makeAutomationTestPanelStore(provider: DarkModeProvider(
            automation: systemEventsCheck(systemEvents),
            isDarkAppearance: { false },
            runScript: { _ in "" }
        ))

        // Opening the panel refreshes every provider.
        try await boundedRefresh(store)
        XCTAssertEqual(darkModeEntry(in: store)?.permission, .denied)

        // System Events quits while idle, then the user grants access in System
        // Settings and reopens the panel.
        systemEvents.quit()
        systemEvents.set(noErr)
        try await boundedRefresh(store)
        XCTAssertEqual(darkModeEntry(in: store)?.permission, .granted)
        XCTAssertEqual(systemEvents.launches, 2, "each verdict that was still needed relaunched System Events")
        XCTAssertFalse(systemEvents.ranOnMainThread, "the Apple Event check must stay off the main thread")
    }

    /// Opening the panel or the palette waits at most the check's timeout for a
    /// System Events that never answers.
    @MainActor
    func testRefreshDoesNotWaitForASystemEventsThatNeverAnswers() async throws {
        let systemEvents = ScriptedAutomationCheck(noErr)
        addTeardownBlock { systemEvents.release(answering: noErr) }
        let automation = systemEventsCheck(systemEvents, timeout: .milliseconds(50))
        await automation.record(.granted)
        let store = try makeAutomationTestPanelStore(provider: DarkModeProvider(
            automation: automation,
            isDarkAppearance: { true },
            runScript: { _ in "" }
        ))

        systemEvents.stall()
        let refreshed = expectation(description: "refreshAll returns while System Events doesn't answer")
        Task { @MainActor in
            await store.refreshAll()
            refreshed.fulfill()
        }
        await fulfillment(of: [refreshed], timeout: 5)
        let entry = darkModeEntry(in: store)
        XCTAssertEqual(entry?.toggleState, true, "the switch shows the appearance")
        XCTAssertEqual(entry?.permission, .granted, "the row keeps the last verdict")
    }

    /// The toggle's own Apple Event shows that access is granted, so the row
    /// and the Settings badge update without waiting for a live check.
    func testToggleThatSucceedsRecordsTheGrant() async throws {
        let automation = recordedVerdictCheck()
        await automation.record(.denied)
        let provider = DarkModeProvider(
            automation: automation,
            isDarkAppearance: { false },
            runScript: { _ in "" }
        )

        try await provider.setState(true)
        let permission = try await boundedPermission(of: provider)
        XCTAssertEqual(permission, .granted)
    }

    /// A denied toggle (-1743) records the denial and still reports it to the
    /// caller.
    func testDeniedToggleRecordsTheDenialAndRethrows() async throws {
        let automation = recordedVerdictCheck()
        await automation.record(.granted)
        let provider = DarkModeProvider(
            automation: automation,
            isDarkAppearance: { false },
            runScript: { _ in throw BuiltinError.missingAutomationPermission }
        )

        do {
            try await provider.setState(true)
            XCTFail("a denied toggle must throw")
        } catch BuiltinError.missingAutomationPermission {
            // Rethrown for PanelStore.toggle, as before.
        }
        let permission = try await boundedPermission(of: provider)
        XCTAssertEqual(permission, .denied)
    }

    // MARK: - Helpers

    /// A System Events check over the scripted target, launched the way the
    /// production check launches System Events. Reads that need an answer get
    /// it well within the default timeout.
    private func systemEventsCheck(
        _ systemEvents: ScriptedAutomationCheck,
        timeout: Duration = .seconds(5)
    ) -> AutomationPermissionCheck {
        AutomationPermissionCheck(
            target: "test.systemevents",
            timeout: timeout,
            launchTarget: { systemEvents.launch() },
            determine: { systemEvents.determine() }
        )
    }

    /// A check whose target isn't running and can't be launched, so `permission`
    /// reports what `setState` recorded.
    private func recordedVerdictCheck() -> AutomationPermissionCheck {
        let systemEvents = ScriptedAutomationCheck(errAEEventNotPermitted, isRunning: false)
        return AutomationPermissionCheck(
            target: "test.systemevents",
            timeout: .seconds(5),
            determine: { systemEvents.determine() }
        )
    }

    @MainActor
    private func darkModeEntry(in store: PanelStore) -> PanelEntry? {
        store.topLevelEntries.first { $0.source == .builtin(.darkMode) }
    }
}
