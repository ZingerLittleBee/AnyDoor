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

    // MARK: - Public state

    private(set) var availableVersion: String? = nil
    private(set) var lastCheckDate: Date? = nil

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
        skippedVersionProvider: { UserDefaults.standard.string(forKey: "SUSkippedVersion") }
    )

    @ObservationIgnored
    private var adapter: any UpdaterAdapter
    @ObservationIgnored
    private let skippedVersionProvider: () -> String?

    init(adapter: any UpdaterAdapter, skippedVersionProvider: @escaping () -> String?) {
        self.adapter = adapter
        self.skippedVersionProvider = skippedVersionProvider
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
    func didFindUpdate(version: String) {
        if let skipped = skippedVersionProvider(), skipped == version {
            availableVersion = nil
        } else {
            availableVersion = version
        }
        lastCheckDate = Date()
    }

    func didNotFindUpdate() {
        availableVersion = nil
        lastCheckDate = Date()
    }

    /// Called when Sparkle aborts a check (e.g., network failure or feed parse error).
    /// We update `lastCheckDate` so the UI reflects "we tried just now" but we
    /// deliberately do NOT clear `availableVersion` — a prior successful check
    /// may still be valid.
    func didFailCheck() {
        lastCheckDate = Date()
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
}
