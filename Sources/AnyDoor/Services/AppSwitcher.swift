import AppKit
import ApplicationServices

@MainActor
enum AppSwitcher {
    /// Grace period for `NSRunningApplication.hide()` (an asynchronous
    /// LaunchServices notification) to take effect before falling back to
    /// Accessibility `kAXHiddenAttribute`. Normal apps hide in ~5–25ms, so the
    /// fallback stays dormant for them and only runs when LaunchServices drops
    /// the hide notification (observed with apps launched hidden as background
    /// services such as ego lite).
    static let hideFallbackDelay: Duration = .milliseconds(80)

    /// Bounds synchronous AX IPC so an unresponsive target app never lingers
    /// on the helper queue.
    nonisolated private static let accessibilityHideTimeout: Float = 0.25

    nonisolated private static let accessibilityQueue = DispatchQueue(
        label: "dev.bybee.AnyDoor.app-switcher.ax",
        qos: .userInteractive
    )

    private static var pendingHideFallback: Task<Void, Never>?
    private static var hideFallbackGeneration: UInt64 = 0

    struct Target {
        let processIdentifier: pid_t
        let isActive: () -> Bool
        let isHidden: () -> Bool
        let isTerminated: () -> Bool
        let requestHide: () -> Void
    }

    static func toggle(bundleID: String, appPath: String) {
        let targets = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .map { app in
                Target(
                    processIdentifier: app.processIdentifier,
                    isActive: { app.isActive },
                    isHidden: { app.isHidden },
                    isTerminated: { app.isTerminated },
                    requestHide: { _ = app.hide() }
                )
            }

        toggle(
            runningTargets: targets,
            activate: {
                // Route activation through Launch Services rather than
                // NSRunningApplication.activate(). The latter is silently
                // ignored on macOS 14+ when called from an .accessory app
                // while another regular app holds keyboard focus (observed
                // with Warp, also reported for Ghostty / iTerm). openApplication
                // is itself a privileged Launch Services call and is allowed
                // to steal focus on behalf of the user.
                activate(at: launchURL(bundleID: bundleID, recordedPath: appPath))
            },
            fallbackHide: { pid in
                hideViaAccessibility(pid: pid)
            }
        )
    }

    @discardableResult
    static func toggle(
        runningTargets: [Target],
        hideFallbackDelay: Duration = hideFallbackDelay,
        activate: () -> Void,
        fallbackHide: @escaping @MainActor (pid_t) -> Void
    ) -> Task<Void, Never>? {
        pendingHideFallback?.cancel()
        pendingHideFallback = nil
        hideFallbackGeneration &+= 1

        if let active = runningTargets.first(where: { $0.isActive() }) {
            active.requestHide()
            let pid = active.processIdentifier
            let generation = hideFallbackGeneration
            let task = Task { @MainActor in
                defer {
                    if hideFallbackGeneration == generation {
                        pendingHideFallback = nil
                    }
                }
                do {
                    try await Task.sleep(for: hideFallbackDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled, hideFallbackGeneration == generation else { return }
                guard !active.isTerminated(), active.isActive(), !active.isHidden() else { return }
                fallbackHide(pid)
            }
            pendingHideFallback = task
            return task
        } else {
            activate()
            return nil
        }
    }

    /// Fallback for apps whose LaunchServices process entry drops
    /// `NSRunningApplication.hide()` (`kLSNotifyApplicationHide`). Setting
    /// `kAXHiddenAttribute` routes directly to the target app's
    /// `NSApplication` hide handler (`PostHideProcess` / `SHOWHIDE`).
    private static func hideViaAccessibility(pid: pid_t) {
        guard AXIsProcessTrusted() else { return }
        accessibilityQueue.async {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, accessibilityHideTimeout)
            AXUIElementSetAttributeValue(axApp, kAXHiddenAttribute as CFString, true as CFBoolean)
        }
    }

    /// The recorded bundle, or Launch Services' copy of the app when the
    /// recorded path is gone (the app was reinstalled under a new name, or the
    /// binding was imported before the app existed on this Mac).
    private static func launchURL(bundleID: String, recordedPath: String) -> URL {
        if !recordedPath.isEmpty, FileManager.default.fileExists(atPath: recordedPath) {
            return URL(fileURLWithPath: recordedPath)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            ?? URL(fileURLWithPath: recordedPath)
    }

    private static func activate(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    }
}
