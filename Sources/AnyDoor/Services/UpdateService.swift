import Foundation
import Observation

/// Façade between Sparkle and the SwiftUI views. Views never import Sparkle;
/// they read this type via `UpdateService.shared` or dependency injection.
///
/// Threading: every property and method runs on `@MainActor`. The injected
/// `UpdaterAdapter` is also `@MainActor`, matching `SPUUpdater`'s isolation.
@MainActor
@Observable
final class UpdateService {

    /// Fixed cadence for scheduled background update checks. Not user-tunable.
    static let defaultCheckInterval: TimeInterval = 86_400
    nonisolated static let betaUpdatesEnabledKey = "updates.betaEnabled"

    // MARK: - Public state

    private(set) var availableVersion: String? = nil

    /// Per-device consent. Deliberately excluded from Config Sync and backups.
    var betaUpdatesEnabled: Bool {
        didSet {
            guard betaUpdatesEnabled != oldValue else { return }
            betaUpdatesEnabledWriter(betaUpdatesEnabled)
            availableVersion = nil
            adapter.resetUpdateCycle()
        }
    }

    var allowedChannels: Set<String> {
        betaUpdatesEnabled ? ["beta"] : []
    }

    var automaticChecksEnabled: Bool {
        didSet {
            // Avoid the echo when we set this from rebind/init.
            guard suppressAdapterEcho == false else { return }
            adapter.automaticallyChecksForUpdates = automaticChecksEnabled
        }
    }

    @ObservationIgnored
    private var suppressAdapterEcho: Bool = false

    // MARK: - Init

    /// Shared instance bound to the production `SPUUpdater` by `AppDelegate`.
    /// Tests build instances directly with a fake adapter.
    static let shared: UpdateService = UpdateService(
        adapter: NullUpdaterAdapter(),
        skippedVersionProvider: { UserDefaults.standard.string(forKey: "SUSkippedVersion") },
        betaUpdatesEnabledProvider: {
            UserDefaults.standard.bool(forKey: UpdateService.betaUpdatesEnabledKey)
        },
        betaUpdatesEnabledWriter: {
            UserDefaults.standard.set($0, forKey: UpdateService.betaUpdatesEnabledKey)
        }
    )

    @ObservationIgnored
    private var adapter: any UpdaterAdapter
    @ObservationIgnored
    private let skippedVersionProvider: () -> String?
    @ObservationIgnored
    private let betaUpdatesEnabledWriter: (Bool) -> Void

    init(
        adapter: any UpdaterAdapter,
        skippedVersionProvider: @escaping () -> String?,
        betaUpdatesEnabledProvider: () -> Bool,
        betaUpdatesEnabledWriter: @escaping (Bool) -> Void
    ) {
        self.adapter = adapter
        self.skippedVersionProvider = skippedVersionProvider
        self.betaUpdatesEnabledWriter = betaUpdatesEnabledWriter
        self.betaUpdatesEnabled = betaUpdatesEnabledProvider()
        self.suppressAdapterEcho = true
        self.automaticChecksEnabled = adapter.automaticallyChecksForUpdates
        self.suppressAdapterEcho = false
        adapter.updateCheckInterval = Self.defaultCheckInterval
    }

    /// Swap in the real Sparkle adapter once `AppDelegate` has constructed the controller.
    func rebind(to adapter: any UpdaterAdapter) {
        self.adapter = adapter
        suppressAdapterEcho = true
        automaticChecksEnabled = adapter.automaticallyChecksForUpdates
        suppressAdapterEcho = false
        adapter.updateCheckInterval = Self.defaultCheckInterval
    }

    // MARK: - User-facing actions

    func checkForUpdates() {
        adapter.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        adapter.checkForUpdatesInBackground()
    }

    func dismissBannerForThisSession() {
        availableVersion = nil
    }

    // MARK: - Sparkle delegate fan-in

    /// Called from the Sparkle delegate when a candidate update is reported.
    func didFindUpdate(internalVersion: String, displayVersion: String) {
        if let skipped = skippedVersionProvider(), skipped == internalVersion {
            availableVersion = nil
        } else {
            availableVersion = displayVersion
        }
    }

    func didNotFindUpdate() {
        availableVersion = nil
    }
}

/// Stand-in used until `AppDelegate.applicationDidFinishLaunching` rebinds the real adapter.
/// Keeps the shared instance usable in previews and dev-mode (where the updater never starts).
@MainActor
private final class NullUpdaterAdapter: UpdaterAdapter {
    var automaticallyChecksForUpdates: Bool = false
    var updateCheckInterval: TimeInterval = 86_400
    func checkForUpdates() {}
    func checkForUpdatesInBackground() {}
    func resetUpdateCycle() {}
}
