import Foundation

/// Abstracts `SPUUpdater` so `UpdateService` can be tested with a fake.
/// All conformers run on the main actor — Sparkle's APIs require it.
@MainActor
protocol UpdaterAdapter: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    /// Seconds between scheduled checks. Sparkle stores this in `SUUpdateCheckInterval`.
    var updateCheckInterval: TimeInterval { get set }

    /// Show Sparkle's standard "checking…" UI; user-initiated.
    func checkForUpdates()
    /// Silent check; populates `UpdateService.availableVersion` via the delegate path.
    func checkForUpdatesInBackground()
}
