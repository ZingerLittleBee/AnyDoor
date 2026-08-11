import Foundation
import Sparkle

/// Production conformance forwarding to a real `SPUUpdater`.
@MainActor
final class SparkleUpdaterAdapter: UpdaterAdapter {
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var updateCheckInterval: TimeInterval {
        get { updater.updateCheckInterval }
        set { updater.updateCheckInterval = newValue }
    }

    func checkForUpdates() { updater.checkForUpdates() }
    func checkForUpdatesInBackground() { updater.checkForUpdatesInBackground() }
    func resetUpdateCycle() { updater.resetUpdateCycle() }
}

/// Translates Sparkle delegate callbacks into `UpdateService` mutations. Kept
/// separate from `UpdateService` so the service has zero Sparkle imports.
final class SparkleUpdaterBridge: NSObject, SPUUpdaterDelegate {
    private let service: UpdateService
    private let betaUpdatesEnabledProvider: @Sendable () -> Bool

    init(
        service: UpdateService,
        betaUpdatesEnabledProvider: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: UpdateService.betaUpdatesEnabledKey)
        }
    ) {
        self.service = service
        self.betaUpdatesEnabledProvider = betaUpdatesEnabledProvider
        super.init()
    }

    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateService.allowedChannels(betaUpdatesEnabled: betaUpdatesEnabledProvider())
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let internalVersion = item.versionString
        let displayVersion = item.displayVersionString
        Task { @MainActor in
            service.didFindUpdate(
                internalVersion: internalVersion,
                displayVersion: displayVersion
            )
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in service.didNotFindUpdate() }
    }
}
