import AppKit
import CoreServices

/// Automation (Apple Events) permission for the apps AnyDoor scripts.
///
/// AnyDoor sends Apple Events to System Events (dark mode, graceful scheduled
/// shutdown) and to Finder (Empty Trash, Image Conversion's Finder selection).
/// Automation is a per-target TCC permission with no "drag into list" pane, so
/// this offers a status check plus a request that shows the standard system
/// prompt. `isGranted` and `request()` cover System Events, the target the
/// Settings and onboarding rows report; `determine(target:askUserIfNeeded:)`
/// checks any target.
///
/// `AEDeterminePermissionToAutomateTarget` reports `procNotFound` when the target
/// app is not running, so `activateSystemEvents()` must run before the first
/// System Events status read.
enum AutomationPermission {
    private static let systemEventsBundleID = "com.apple.systemevents"
    private static let systemEventsURL = URL(
        fileURLWithPath: "/System/Library/CoreServices/System Events.app")

    /// Launches System Events (faceless, non-activating) so the status check
    /// returns a real verdict instead of `procNotFound`.
    static func activateSystemEvents() async {
        guard NSRunningApplication
            .runningApplications(withBundleIdentifier: systemEventsBundleID)
            .isEmpty
        else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(
            at: systemEventsURL, configuration: config)
    }

    static var isGranted: Bool {
        determine(target: systemEventsBundleID, askUserIfNeeded: false) == noErr
    }

    /// Shows the system Automation prompt when the state is undetermined.
    /// Blocks until the user responds — call off the main actor. Returns true
    /// when AnyDoor ends up authorized.
    static func request() -> Bool {
        determine(target: systemEventsBundleID, askUserIfNeeded: true) == noErr
    }

    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether AnyDoor may send Apple Events to the running app `bundleID`:
    /// `noErr` when allowed, `errAEEventNotPermitted` when denied,
    /// `errAEEventWouldRequireUserConsent` when the user has not decided yet and
    /// `askUserIfNeeded` is false, and `procNotFound` when the target is not
    /// running. It waits for the target app itself to answer, so it blocks for
    /// as long as the target hangs, and it also waits for the user's answer
    /// when `askUserIfNeeded` is true. Never call it on the main thread.
    static func determine(target bundleID: String, askUserIfNeeded: Bool) -> OSStatus {
        var address = AEAddressDesc()
        let createStatus = bundleID.withCString {
            AECreateDesc(typeApplicationBundleID, $0, bundleID.utf8.count, &address)
        }
        guard createStatus == noErr else { return OSStatus(createStatus) }
        defer { AEDisposeDesc(&address) }
        return AEDeterminePermissionToAutomateTarget(
            &address, typeWildCard, typeWildCard, askUserIfNeeded)
    }
}
