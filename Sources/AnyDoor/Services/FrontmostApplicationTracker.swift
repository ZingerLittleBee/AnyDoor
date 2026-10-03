import AppKit
import PluginSupport

/// Where a menu-bar commit sends its ⌘V once the panel has closed.
enum ClipboardHistoryPasteTarget: Equatable, Sendable {
    /// Whatever app is frontmost: the panel never activates AnyDoor, so that
    /// is still the app the user was working in.
    case frontmost
    /// The click that opened the panel activated another app, as a click on
    /// another display's menu bar does with "Displays have separate Spaces".
    /// The app with this process ID was frontmost before the click, so it is
    /// brought back before the paste.
    case application(pid_t)
    /// The click activated another app, and the app before it is unknown or
    /// is AnyDoor itself. The entry is copied but never pasted.
    case unavailable
}

/// One click on the status item, in event time (`NSEvent.timestamp`, seconds
/// of system uptime).
struct StatusItemClick: Equatable, Sendable {
    /// How far before the mouse-up the click is assumed to begin when its
    /// mouse-down went unseen.
    static let fallbackLead: TimeInterval = 0.5
    /// The longest press taken at face value. An older mouse-down is from an
    /// earlier click whose mouse-up never reached the action, so it could
    /// widen the click over an unrelated app switch.
    static let maximumHold: TimeInterval = 5

    let began: TimeInterval
    let ended: TimeInterval

    /// `mouseDown` is the latest mouse-down seen on the status item. The
    /// button tracks the mouse from that mouse-down to this mouse-up, so one
    /// shortly before `mouseUp` began this click.
    init(mouseDown: TimeInterval?, mouseUp: TimeInterval) {
        if let mouseDown, mouseDown <= mouseUp,
            mouseUp - mouseDown <= Self.maximumHold
        {
            began = mouseDown
        } else {
            began = mouseUp - Self.fallbackLead
        }
        ended = mouseUp
    }
}

/// Recent app activations, in the order AnyDoor received them, timestamped
/// on the same clock as `NSEvent.timestamp`.
///
/// A click on the menu bar of a display other than the active one activates
/// that display's frontmost app before the status item's action runs, and
/// its notification can arrive on either side of that action. The history
/// keeps enough of the past that a commit, made long after both, can still
/// tell which app the user was working in before the click.
struct ApplicationActivationHistory: Equatable, Sendable {
    struct Activation: Equatable, Sendable {
        let processID: pid_t
        let time: TimeInterval
    }

    /// Plenty for one panel showing; an older click whose prior app has
    /// rolled off resolves to `.unavailable`, never to a wrong app.
    static let capacity = 32
    /// How long after the mouse-up an activation still counts as caused by
    /// the click. Workspace notifications arrive within milliseconds; a
    /// deliberate app switch this soon after opening the panel is unlikely.
    static let lateActivationGrace: TimeInterval = 1.0

    private(set) var activations: [Activation] = []

    /// Records that `processID` became the active app at `time`. A repeat of
    /// the current app changes nothing.
    mutating func record(_ processID: pid_t, at time: TimeInterval) {
        guard activations.last?.processID != processID else { return }
        activations.append(Activation(processID: processID, time: time))
        if activations.count > Self.capacity {
            activations.removeFirst(activations.count - Self.capacity)
        }
    }

    /// Where a paste from the panel that `click` opened should go.
    ///
    /// Activations of other apps from the mouse-down to `lateActivationGrace`
    /// after the mouse-up are the click's. None, or ones that end on the app
    /// that was already active, leave the frontmost app as the target, so a
    /// single-display click changes nothing. Otherwise the target is the app
    /// that was active before the click. AnyDoor's own activations never
    /// count as the click's.
    func pasteTarget(
        after click: StatusItemClick,
        selfProcessID: pid_t
    ) -> ClipboardHistoryPasteTarget {
        let windowEnd = click.ended + Self.lateActivationGrace
        let clickActivations = activations.filter {
            $0.time >= click.began && $0.time <= windowEnd
                && $0.processID != selfProcessID
        }
        guard let activatedByClick = clickActivations.last else {
            return .frontmost
        }
        guard
            let prior = activations.last(where: { $0.time < click.began }),
            prior.processID != selfProcessID
        else {
            return .unavailable
        }
        if prior.processID == activatedByClick.processID { return .frontmost }
        return .application(prior.processID)
    }
}

/// Keeps an `ApplicationActivationHistory` from workspace activation
/// notifications for as long as AnyDoor runs. The observer only appends a
/// value, so it stays cheap on the main thread.
@MainActor
final class FrontmostApplicationTracker {
    private(set) var history = ApplicationActivationHistory()
    private var observer: NSObjectProtocol?

    /// Seeds the history with the current frontmost app and starts
    /// observing. Calling it again does nothing.
    func start() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication {
            history.record(
                front.processIdentifier,
                at: ProcessInfo.processInfo.systemUptime
            )
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Stamped on arrival: the click that caused an activation always
            // precedes it, so the stamp never lands before that click.
            let time = ProcessInfo.processInfo.systemUptime
            guard
                let app = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication
            else { return }
            let processID = app.processIdentifier
            MainThreadIsolation.run {
                self?.history.record(processID, at: time)
            }
        }
    }
}

@MainActor
enum ApplicationReactivation {
    /// Asks macOS to bring `app` to the front. `NSRunningApplication.activate()`
    /// is ignored on macOS 14+ when an accessory app calls it while another
    /// app is active, so this goes through Launch Services, which honors the
    /// user-initiated focus transfer. Activation is asynchronous; check
    /// `isActive` before relying on it.
    static func activate(_ app: NSRunningApplication) {
        guard let bundleURL = app.bundleURL else {
            app.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration
        ) { _, _ in }
    }
}
