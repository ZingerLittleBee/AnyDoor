import ApplicationServices
import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "clearNotifications")

/// Live Notification Center surface over the Accessibility C API. Every
/// AXUIElement is created, read, and released within one block on `queue`;
/// only Sendable snapshots and results leave it.
struct AccessibilitySystemNotificationSurface: SystemNotificationSurface {
    static let bundleIdentifier = "com.apple.notificationcenterui"

    private static let queue = DispatchQueue(
        label: "dev.bybee.AnyDoor.system-notifications",
        qos: .userInitiated
    )

    private static let walker = NotificationTreeWalker()
    /// Messaging timeout for each read, clamped to the time left in the walk.
    private static let readTimeout: Duration = .milliseconds(250)
    /// Messaging timeout for performing the chosen action, clamped to the time
    /// left in the pass.
    private static let performTimeout: Duration = .seconds(1)
    /// Budget for one walk, clamped to the pass's time limit.
    private static let walkBudget: Duration = .milliseconds(1_500)

    let pid: pid_t
    let labels: SystemNotificationDismissLabels

    /// The language Notification Center runs in (`AXPreferredLanguage`), or
    /// nil when it cannot be read.
    static func preferredLanguage(pid: pid_t, timeout: Duration = .milliseconds(500)) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let deadline = AXDeadline(after: timeout)
                let application = AXUIElementCreateApplication(pid)
                guard deadline.prepare(application, timeout: timeout) else {
                    continuation.resume(returning: nil)
                    return
                }
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(
                    application, "AXPreferredLanguage" as CFString, &value
                )
                continuation.resume(returning: error == .success ? value as? String : nil)
            }
        }
    }

    func pass(
        timeLimit: Duration,
        choose: @escaping @Sendable ([SystemNotificationElement]) -> SystemNotificationChoice?
    ) async -> SystemNotificationPass {
        await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: passOnQueue(timeLimit: timeLimit, choose: choose))
            }
        }
    }

    private func passOnQueue(
        timeLimit: Duration,
        choose: ([SystemNotificationElement]) -> SystemNotificationChoice?
    ) -> SystemNotificationPass {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        let passDeadline = AXDeadline(after: timeLimit)
        let reader = LiveNotificationTreeReader(
            timeout: Self.readTimeout,
            deadline: AXDeadline(after: min(Self.walkBudget, timeLimit))
        )
        let scan = Self.walker.scan(
            application: AXUIElementCreateApplication(pid),
            reader: reader,
            labels: labels
        )
        let elements = scan.candidates.map(\.element)
        logger.debug("Read \(elements.count) notifications, complete: \(scan.isComplete)")
        guard let choice = choose(elements), scan.candidates.indices.contains(choice.index) else {
            return SystemNotificationPass(present: elements, isComplete: scan.isComplete, actedOn: nil)
        }
        let (element, node) = scan.candidates[choice.index]
        guard passDeadline.prepare(node, timeout: Self.performTimeout) else {
            logger.debug("No time left in the pass to act on \(element.subrole, privacy: .public)")
            return SystemNotificationPass(present: elements, isComplete: scan.isComplete, actedOn: nil)
        }
        // Whatever AX reports, the next read shows whether the notification
        // is gone; the error is only logged. An invalid element was already
        // dismissed, and a timeout may still have reached Notification Center.
        let error = AXUIElementPerformAction(node, choice.action as CFString)
        if error != .success {
            logger.error("Dismiss action on \(element.subrole, privacy: .public) failed with AX error \(error.rawValue)")
        }
        return SystemNotificationPass(present: elements, isComplete: scan.isComplete, actedOn: element.id)
    }
}

/// A monotonic deadline for synchronous AX messaging.
private struct AXDeadline {
    /// Below this, a call cannot usefully complete (and a zero timeout would
    /// mean "use the system default" to AX).
    private static let minimumTimeout = 0.001

    private let uptimeNanoseconds: UInt64

    init(after duration: Duration) {
        // Capped at an hour: these budgets are seconds long.
        let seconds = min(max(Self.seconds(duration), 0), 3_600)
        uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    }

    /// Sets `element`'s messaging timeout to `timeout`, clamped to the time
    /// left. AX does not inherit an application element's timeout on
    /// references read from its attributes, so every element needs its own.
    /// False once the deadline has passed.
    func prepare(_ element: AXUIElement, timeout: Duration) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < uptimeNanoseconds else { return false }
        let remaining = Double(uptimeNanoseconds - now) / 1_000_000_000
        let clamped = min(Self.seconds(timeout), remaining)
        guard clamped >= Self.minimumTimeout else { return false }
        return AXUIElementSetMessagingTimeout(element, Float(clamped)) == .success
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// Reads live AX elements; used only on the surface's queue. Reads structure
/// (subroles, identifiers, window titles, children, action names), never an
/// element's text.
private struct LiveNotificationTreeReader: NotificationTreeReading {
    let timeout: Duration
    let deadline: AXDeadline

    func windows(of application: AXUIElement) -> NotificationTreeRead<[AXUIElement]> {
        attribute(application, kAXWindowsAttribute)
    }

    func subrole(of node: AXUIElement) -> NotificationTreeRead<String> {
        attribute(node, kAXSubroleAttribute)
    }

    func identifier(of node: AXUIElement) -> NotificationTreeRead<String> {
        attribute(node, kAXIdentifierAttribute)
    }

    func title(of window: AXUIElement) -> NotificationTreeRead<String> {
        attribute(window, kAXTitleAttribute)
    }

    func children(of node: AXUIElement) -> NotificationTreeRead<[AXUIElement]> {
        attribute(node, kAXChildrenAttribute)
    }

    func actions(of node: AXUIElement) -> NotificationTreeRead<[String]> {
        guard deadline.prepare(node, timeout: timeout) else { return .failed }
        var names: CFArray?
        let error = AXUIElementCopyActionNames(node, &names)
        return NotificationTreeRead(error, value: names as? [String])
    }

    func identity(of node: AXUIElement) -> UInt {
        CFHash(node)
    }

    private func attribute<Value>(_ element: AXUIElement, _ name: String) -> NotificationTreeRead<Value> {
        guard deadline.prepare(element, timeout: timeout) else { return .failed }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return NotificationTreeRead(error, value: value as? Value)
    }
}
