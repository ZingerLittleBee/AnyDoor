import Foundation

/// A notification element seen while walking Notification Center. Carries its
/// identity, subrole, and raw action names only, never any of its text.
struct SystemNotificationElement: Sendable, Equatable {
    var id: UInt
    var subrole: String
    /// Raw AX action names, e.g. `"AXPress"` or
    /// `"Name:Close\nTarget:0x0\nSelector:(null)"`.
    var actions: [String]
}

/// The element to act on, by position in one pass's snapshot, and the raw
/// action name to perform on it.
struct SystemNotificationChoice: Sendable, Equatable {
    var index: Int
    var action: String
}

/// Decides which Notification Center windows may hold notifications, which
/// elements are notifications, and which of their actions dismisses them.
enum SystemNotificationDismissPolicy {
    /// Subroles Notification Center gives banners, alerts, and their stacks.
    /// Matched exactly: a prefix match would also catch unrelated elements
    /// such as `AXNotificationCenterNextFocus`.
    static let notificationSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        "AXNotificationCenterBannerStack",
        "AXNotificationCenterAlert",
        "AXNotificationCenterAlertStack",
    ]

    /// Subrole of the windows Notification Center shows banners and alerts in.
    static let bannerWindowSubrole = "AXSystemDialog"

    /// Identifier prefix of widget content, as third-party tools report it for
    /// desktop widgets on macOS 26; the panel's widgets are expected to share
    /// it.
    static let widgetIdentifierPrefix = "widget-local:"
    /// Identifier of the panel's Edit Widgets control, reported the same way.
    static let widgetEditorIdentifier = "widget-editor-button"

    static func isNotification(subrole: String) -> Bool {
        notificationSubroles.contains(subrole)
    }

    static func isBannerWindow(subrole: String) -> Bool {
        subrole == bannerWindowSubrole
    }

    /// Notification Center's panel window is expected to carry its localized
    /// name as the title, and its desktop widget windows not to.
    static func isPanelWindow(title: String, labels: SystemNotificationDismissLabels) -> Bool {
        labels.windowTitles.contains(title)
    }

    /// Whether an element with this `AXIdentifier` is widget content, which
    /// holds no notifications.
    static func isWidget(identifier: String) -> Bool {
        identifier.hasPrefix(widgetIdentifierPrefix) || identifier == widgetEditorIdentifier
    }

    /// Extracts the display label of a custom action
    /// (`"Name:Close\nTarget:0x0\nSelector:(null)"` -> `"Close"`). Standard
    /// actions such as `"AXPress"` have no label.
    static func customActionLabel(_ raw: String) -> String? {
        guard raw.hasPrefix("Name:") else { return nil }
        return String(raw.dropFirst("Name:".count).prefix { $0 != "\n" })
    }

    /// The raw action that dismisses an element offering `actions`, or nil.
    ///
    /// Tries the dismiss keys in priority order and settles on the first one
    /// any action matches, so `[Close, Clear All]` yields "Clear All". Matches
    /// by label only, never by position: an app's own notification actions
    /// ("Delete", "Mark as Completed") are custom actions too. When more than
    /// one action matches the chosen label, the element is left alone, since
    /// an app may have named its own action "Close" as well.
    static func dismissAction(
        in actions: [String],
        labels: SystemNotificationDismissLabels
    ) -> String? {
        let labeled = actions.compactMap { raw in
            customActionLabel(raw).map { (raw: raw, label: $0) }
        }
        for accepted in labels.actionLabels where !accepted.isEmpty {
            let matches = labeled.filter { accepted.contains($0.label) }
            if matches.count > 1 { return nil }
            if let match = matches.first { return match.raw }
        }
        return nil
    }

    /// The first element, in document order, that is not being skipped and
    /// offers a recognizable dismiss action.
    static func nextTarget(
        in elements: [SystemNotificationElement],
        labels: SystemNotificationDismissLabels,
        skipping: Set<UInt>
    ) -> SystemNotificationChoice? {
        for (index, element) in elements.enumerated() where !skipping.contains(element.id) {
            if let action = dismissAction(in: element.actions, labels: labels) {
                return SystemNotificationChoice(index: index, action: action)
            }
        }
        return nil
    }
}
