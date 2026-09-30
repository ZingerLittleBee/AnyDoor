import AppKit
import ApplicationServices
import OSLog
import PluginInterface

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "clearNotifications")

/// Dismisses the banners, alerts, and stacks Notification Center is showing
/// (and the items in its panel when it is already open) by invoking
/// Notification Center's own localized dismiss actions through Accessibility.
/// It never opens the panel and never reads notification text.
///
/// Every outcome is reported through a toast; `run()` never propagates.
actor ClearNotificationsProvider: ActionProvider {
    let itemKey: BuiltinItem = .clearNotifications

    /// Accessibility is requested at startup by `HotkeyService`; like
    /// `WindowLayoutProvider`, the row carries no permission badge and `run()`
    /// reports a missing grant instead.
    var permission: PermissionStatus { .notRequired }

    /// Label resolution reads Notification Center's whole string table, so
    /// it is kept per bundle path and language.
    private var cachedLabels: (key: String, labels: SystemNotificationDismissLabels)?

    func run() async {
        // Only checks: HotkeyService owns the Accessibility prompt.
        guard AXIsProcessTrusted() else {
            await show(ToastStyle.failure, .toastClearNotificationsNeedsAccessibility)
            return
        }
        let center = await MainActor.run {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: AccessibilitySystemNotificationSurface.bundleIdentifier
            ).first.map { ($0.processIdentifier, $0.bundleURL) }
        }
        guard let center else {
            logger.info("Notification Center is not running")
            await show(ToastStyle.info, .toastClearNotificationsNone)
            return
        }
        let (pid, runningBundleURL) = center
        let bundleURL = runningBundleURL ?? SystemNotificationDismissLabels.defaultBundleURL
        let language = await AccessibilitySystemNotificationSurface.preferredLanguage(pid: pid)
        let labels = resolvedLabels(bundleURL: bundleURL, languages: language.map { [$0] } ?? Self.globalLanguages())
        let outcome = await SystemNotificationDismisser(
            surface: AccessibilitySystemNotificationSurface(pid: pid, labels: labels),
            labels: labels
        ).run()
        logger.info("Clear notifications finished: \(String(describing: outcome), privacy: .public)")
        switch outcome {
        case .nothingToDismiss: await show(ToastStyle.info, .toastClearNotificationsNone)
        case .dismissed: await show(ToastStyle.success, .toastClearNotificationsSuccess)
        case .partial: await show(ToastStyle.failure, .toastClearNotificationsPartial)
        case .failed: await show(ToastStyle.failure, .toastClearNotificationsFailed)
        }
    }

    private func resolvedLabels(bundleURL: URL, languages: [String]) -> SystemNotificationDismissLabels {
        let key = bundleURL.path + "|" + languages.joined(separator: ",")
        if let cachedLabels, cachedLabels.key == key { return cachedLabels.labels }
        let resolved = SystemNotificationDismissLabels.resolve(bundleURL: bundleURL, languages: languages)
        if !resolved.isLanguageKnown {
            logger.info("Notification Center's language is unknown; accepting every localization's labels")
        }
        if resolved.actionLabels.allSatisfy(\.isEmpty) {
            logger.error("Notification Center's string table has no dismiss labels")
        }
        cachedLabels = (key, resolved)
        return resolved
    }

    /// The user's global language list. Deliberately not
    /// `Locale.preferredLanguages`, which follows a language chosen for
    /// AnyDoor alone rather than the one Notification Center runs in.
    private static func globalLanguages() -> [String] {
        let value = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return (value as? [String]) ?? []
    }

    private func show(_ style: (String) -> ToastStyle, _ key: L10n.Key) async {
        let message = await MainActor.run { L(key) }
        await ToastPresenter.shared.show(style(message))
    }
}
