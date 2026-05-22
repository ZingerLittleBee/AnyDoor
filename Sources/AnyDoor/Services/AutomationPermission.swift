import AppKit
import CoreServices

/// Automation (Apple Events) permission for the apps AnyDoor scripts.
///
/// AnyDoor sends Apple Events to System Events (the dark-mode toggle). Automation
/// is a per-target TCC permission with no "drag into list" pane, so this offers a
/// status check plus a request that shows the standard system prompt.
///
/// `AEDeterminePermissionToAutomateTarget` reports `procNotFound` when the target
/// app is not running, so `activateSystemEvents()` must run before the first
/// status read.
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
        determine(askUserIfNeeded: false) == noErr
    }

    /// Shows the system Automation prompt when the state is undetermined.
    /// Blocks until the user responds — call off the main actor. Returns true
    /// when AnyDoor ends up authorized.
    static func request() -> Bool {
        determine(askUserIfNeeded: true) == noErr
    }

    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func determine(askUserIfNeeded: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let bundleID = systemEventsBundleID
        let createStatus = bundleID.withCString {
            AECreateDesc(typeApplicationBundleID, $0, bundleID.utf8.count, &target)
        }
        guard createStatus == noErr else { return OSStatus(createStatus) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, askUserIfNeeded)
    }
}
