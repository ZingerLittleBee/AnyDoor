import CoreServices
import Foundation
import PluginInterface
import XCTest
@testable import AnyDoor

/// The bounded, non-prompting Automation check that the Dark Mode and Empty
/// Trash rows and the Settings and onboarding permission rows read. Every
/// target is scripted, so no test reaches TCC or launches an app.
final class AutomationPermissionCheckTests: XCTestCase {

    /// System Events quits when idle, and a check of a target that isn't
    /// running gives no verdict. The check launches the target, but only while
    /// a verdict is still needed: before the first one, and while denied.
    func testStoppedTargetIsLaunchedOnlyWhileAVerdictIsNeeded() async throws {
        let target = ScriptedAutomationCheck(errAEEventNotPermitted, isRunning: false)
        let check = AutomationPermissionCheck(
            target: "test.target",
            timeout: .seconds(5),
            launchTarget: { target.launch() },
            determine: { target.determine() }
        )

        var status = try await boundedStatus(of: check)
        XCTAssertEqual(status, .denied, "the first read launches the target for a verdict")
        XCTAssertEqual(target.launches, 1)

        // The target quits while idle, and the user grants access in System
        // Settings meanwhile: only a live answer can clear the denial.
        target.quit()
        target.set(noErr)
        status = try await boundedStatus(of: check)
        XCTAssertEqual(status, .granted, "the read relaunches the target to see the grant")
        XCTAssertEqual(target.launches, 2)

        // Granted, and the target quits again: nothing to clear.
        target.quit()
        status = try await boundedStatus(of: check)
        XCTAssertEqual(status, .granted, "the last verdict stands")
        XCTAssertEqual(target.launches, 2, "a granted verdict never launches the target")
    }

    /// A target that stops answering ties up one check however often the rows
    /// poll, and reads after the check's timeout don't wait on it again.
    func testReadsWhileTheTargetHangsShareOneCheck() async throws {
        let target = ScriptedAutomationCheck(errAEEventNotPermitted)
        addTeardownBlock { target.release(answering: noErr) }
        let timeout = Duration.milliseconds(500)
        let check = AutomationPermissionCheck(
            target: "test.target", timeout: timeout, determine: { target.determine() }
        )
        await check.record(.granted)

        target.stall()
        let firstRead = try await boundedStatus(of: check)
        XCTAssertEqual(firstRead, .granted, "the last verdict stands while the target doesn't answer")
        await waitUntil("the stuck check reaches the target") { target.entries == 1 }

        // The check has run past its timeout: reads report the last verdict at
        // once instead of each waiting out the timeout again.
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let read = try await boundedStatus(of: check)
            XCTAssertEqual(read, .granted)
            XCTAssertLessThan(ContinuousClock.now - start, timeout, "a read after the timeout returns at once")
        }
        XCTAssertEqual(target.entries, 1, "reads share the stuck check instead of starting more")

        // The target answers again, with access revoked in the meantime.
        target.release(answering: errAEEventNotPermitted)
        await waitUntil("the answer reaches the next reads") {
            (try? await boundedStatus(of: check)) == .denied
        }

        // It hangs again before it can report a grant: a fresh check gets stuck,
        // and reads keep the last verdict instead of the unreported grant.
        let entriesBeforeSecondHang = target.entries
        target.set(noErr)
        target.stall()
        let secondHang = try await boundedStatus(of: check)
        XCTAssertEqual(secondHang, .denied)
        await waitUntil("a fresh check reaches the target") {
            target.entries == entriesBeforeSecondHang + 1
        }

        target.release(answering: noErr)
        await waitUntil("the grant reaches the next reads") {
            (try? await boundedStatus(of: check)) == .granted
        }
    }

    /// Finder's check has no launcher. While Finder isn't running, the verdict
    /// the caller's own Apple Event found stands until a live check answers.
    func testRecordedVerdictStandsUntilTheTargetAnswers() async throws {
        let target = ScriptedAutomationCheck(noErr, isRunning: false)
        let check = AutomationPermissionCheck(
            target: "test.target", timeout: .seconds(5), determine: { target.determine() }
        )

        var status = try await boundedStatus(of: check)
        XCTAssertEqual(status, .undetermined, "nothing is known before the first verdict")

        await check.record(.denied)
        status = try await boundedStatus(of: check)
        XCTAssertEqual(status, .denied)

        await check.record(.granted)
        status = try await boundedStatus(of: check)
        XCTAssertEqual(status, .granted)

        // The target runs again and answers: its live verdict replaces the
        // recorded one.
        target.launch()
        target.set(errAEEventNotPermitted)
        status = try await boundedStatus(of: check)
        XCTAssertEqual(status, .denied)
    }
}
