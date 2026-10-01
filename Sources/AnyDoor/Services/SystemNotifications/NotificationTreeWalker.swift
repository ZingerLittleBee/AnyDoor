import ApplicationServices
import Foundation

/// Result of one accessibility read.
enum NotificationTreeRead<Value> {
    case value(Value)
    /// The attribute has no value or is unsupported: legitimately empty.
    case empty
    /// The read failed or was cut short (an AX error, a timeout, or the walk's
    /// deadline), so the tree may hold more than the walk saw.
    case failed
}

extension NotificationTreeRead: Equatable where Value: Equatable {}

extension NotificationTreeRead {
    /// Classifies one AX read. Success, no value, and an unsupported attribute
    /// report what the element legitimately holds; any other error (a
    /// timeout, a busy or vanished element) means the read failed.
    /// - Parameter value: The value read, already cast to `Value`; nil when
    ///   there was none or it had another type.
    init(_ error: AXError, value: Value?) {
        switch error {
        case .success: self = value.map { .value($0) } ?? .empty
        case .noValue, .attributeUnsupported: self = .empty
        default: self = .failed
        }
    }
}

/// Read access to Notification Center's accessibility tree. Production reads
/// live AXUIElements on the surface's serial queue; tests use an in-memory
/// fixture. Only structure is read (subroles, identifiers, window titles,
/// children, action names), never an element's text.
protocol NotificationTreeReading {
    associatedtype Node
    func windows(of application: Node) -> NotificationTreeRead<[Node]>
    func subrole(of node: Node) -> NotificationTreeRead<String>
    /// The developer identifier (`AXIdentifier`), not user-visible text.
    func identifier(of node: Node) -> NotificationTreeRead<String>
    func title(of window: Node) -> NotificationTreeRead<String>
    func children(of node: Node) -> NotificationTreeRead<[Node]>
    func actions(of node: Node) -> NotificationTreeRead<[String]>
    func identity(of node: Node) -> UInt
}

/// The notifications one walk found, in document order.
struct NotificationTreeScan<Node> {
    var candidates: [(element: SystemNotificationElement, node: Node)]
    /// False when a read failed or a budget cut the walk short: more
    /// notifications may exist than `candidates` lists.
    var isComplete: Bool
}

/// Walks Notification Center's banner and panel windows for notification
/// elements. It enters no other window, no widget content inside the windows
/// it walks, and no notification, whose children are its private text.
struct NotificationTreeWalker: Sendable {
    var maxDepth = 12
    /// Elements a walk may read, windows included.
    var nodeBudget = 1_500

    func scan<Reader: NotificationTreeReading>(
        application: Reader.Node,
        reader: Reader,
        labels: SystemNotificationDismissLabels
    ) -> NotificationTreeScan<Reader.Node> {
        var candidates: [(element: SystemNotificationElement, node: Reader.Node)] = []
        var isComplete = true
        var remaining = nodeBudget

        func spend() -> Bool {
            guard remaining > 0 else {
                isComplete = false
                return false
            }
            remaining -= 1
            return true
        }

        /// Visits `node`'s children, unless it is widget content: that holds
        /// no notifications, so it counts as legitimately empty rather than
        /// spending the walk's budget. An element whose identifier cannot be
        /// read is entered as usual.
        func visitChildren(of node: Reader.Node, depth: Int) {
            if case .value(let identifier) = reader.identifier(of: node),
               SystemNotificationDismissPolicy.isWidget(identifier: identifier) {
                return
            }
            switch reader.children(of: node) {
            case .value(let children):
                for child in children { visit(child, depth: depth + 1) }
            case .empty:
                break
            case .failed:
                isComplete = false
            }
        }

        func visit(_ node: Reader.Node, depth: Int) {
            guard depth <= maxDepth else {
                isComplete = false
                return
            }
            guard spend() else { return }
            switch reader.subrole(of: node) {
            case .value(let subrole) where SystemNotificationDismissPolicy.isNotification(subrole: subrole):
                let actions: [String]
                switch reader.actions(of: node) {
                case .value(let names):
                    actions = names
                case .empty:
                    actions = []
                case .failed:
                    // Still counted as present; its dismiss action is unknown
                    // until a later pass reads it.
                    actions = []
                    isComplete = false
                }
                candidates.append((
                    SystemNotificationElement(id: reader.identity(of: node), subrole: subrole, actions: actions),
                    node
                ))
            case .value, .empty:
                visitChildren(of: node, depth: depth)
            case .failed:
                // It may be a notification: count the walk as incomplete, and
                // don't enter what could be one.
                isComplete = false
            }
        }

        let windows: [Reader.Node]
        switch reader.windows(of: application) {
        case .value(let found):
            windows = found
        case .empty:
            return NotificationTreeScan(candidates: [], isComplete: true)
        case .failed:
            return NotificationTreeScan(candidates: [], isComplete: false)
        }

        // Banner windows first so the budget reaches on-screen notifications
        // before the panel's list. Each window's subrole is read once.
        var bannerWindows: [Reader.Node] = []
        var panelWindows: [Reader.Node] = []
        for window in windows {
            guard spend() else { break }
            switch reader.subrole(of: window) {
            case .value(let subrole) where SystemNotificationDismissPolicy.isBannerWindow(subrole: subrole):
                bannerWindows.append(window)
                continue
            case .value, .empty:
                break
            case .failed:
                isComplete = false
                continue
            }
            switch reader.title(of: window) {
            case .value(let title) where SystemNotificationDismissPolicy.isPanelWindow(title: title, labels: labels):
                panelWindows.append(window)
            case .value, .empty:
                break // Another Notification Center window, such as a desktop widget.
            case .failed:
                isComplete = false
            }
        }
        for window in bannerWindows + panelWindows {
            visitChildren(of: window, depth: 0)
        }
        return NotificationTreeScan(candidates: candidates, isComplete: isComplete)
    }
}
