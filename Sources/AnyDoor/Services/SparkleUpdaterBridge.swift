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

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    func checkForUpdates() { updater.checkForUpdates() }
    func checkForUpdatesInBackground() { updater.checkForUpdatesInBackground() }
}

/// Translates Sparkle delegate callbacks into `UpdateService` mutations. Kept
/// separate from `UpdateService` so the service has zero Sparkle imports.
final class SparkleUpdaterBridge: NSObject, SPUUpdaterDelegate {
    private let service: UpdateService

    init(service: UpdateService) {
        self.service = service
        super.init()
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in service.didFindUpdate(version: version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in service.didNotFindUpdate() }
    }
}
