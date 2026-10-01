import Foundation
@testable import AnyDoor

// Test support for Clear Notifications: the dismiss labels Notification
// Center resolves in two languages, and the raw form of its custom actions.

enum SystemNotificationFixture {
    /// A custom action's raw AX name, as SwiftUI's
    /// `accessibilityAction(named:)` exposes it.
    static func action(_ label: String) -> String { "Name:\(label)\nTarget:0x0\nSelector:(null)" }

    /// Labels as resolved for an English Notification Center.
    static let english = SystemNotificationDismissLabels(
        actionLabels: [["Clear All"], ["Dismiss All"], ["Close"], ["Dismiss"]],
        windowTitles: ["Notification Center"],
        isLanguageKnown: true
    )

    /// Labels as resolved for a Simplified Chinese Notification Center, where
    /// "Close" and "Dismiss" share one translation.
    static let chinese = SystemNotificationDismissLabels(
        actionLabels: [["全部清除"], ["全部关闭"], ["关闭"], ["关闭"]],
        windowTitles: ["通知中心"],
        isLanguageKnown: true
    )

    /// Creates an empty `NotificationCenter.app`-shaped bundle directory under
    /// a fresh temporary location; the caller removes it.
    static func makeBundleDirectory() throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationCenter-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Resources", isDirectory: true),
            withIntermediateDirectories: true
        )
        return bundle
    }
}
