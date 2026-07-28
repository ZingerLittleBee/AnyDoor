import AppKit
import Foundation
import Observation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "sync")

/// Owns the optional `SyncEngine` and the user-facing sync state the Settings
/// UI binds to. Enable/disable take effect immediately — no relaunch.
@MainActor
@Observable
final class SyncCoordinator {
    static let shared = SyncCoordinator()

    enum Status: Equatable {
        case idle
        case waitingFirstSync
        case synced(Date)
        case failed(Date, SyncFailureReason)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private(set) var engine: SyncEngine?

    private(set) var status: Status = .idle
    private(set) var isEnabled = false
    private(set) var folderPath: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: SyncDefaultsKeys.enabled)
        folderPath = defaults.string(forKey: SyncDefaultsKeys.folderPath)
    }

    /// Called once at launch after the stores are seeded.
    func bootstrap(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        if isEnabled {
            startEngine()
        }
    }

    /// Enable sync against `folderURL` (also the path for changing the folder
    /// while enabled — the engine is rebuilt on the new transport).
    func enable(folderURL: URL) {
        defaults.set(folderURL.path, forKey: SyncDefaultsKeys.folderPath)
        defaults.set(true, forKey: SyncDefaultsKeys.enabled)
        folderPath = folderURL.path
        isEnabled = true
        stopEngine()
        startEngine()
    }

    /// Disable sync. Local config, the machine's state file in the folder,
    /// and the persisted local document all stay — re-enabling resumes.
    func disable() {
        defaults.set(false, forKey: SyncDefaultsKeys.enabled)
        isEnabled = false
        stopEngine()
        status = .idle
    }

    private func startEngine() {
        guard let modelContainer else { return }
        guard let path = folderPath else {
            status = .failed(Date(), .folderMissing)
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            logger.warning("sync folder missing, engine not started: \(path)")
            status = .failed(Date(), .folderMissing)
            return
        }
        let engine = SyncEngine(
            config: SyncEngine.Configuration(
                deviceID: SyncEngine.ensuredDeviceID(in: defaults),
                deviceName: Host.current().localizedName
            ),
            context: modelContainer.mainContext,
            defaults: defaults,
            transport: SyncFolderTransport(folderURL: URL(fileURLWithPath: path, isDirectory: true)),
            stateStore: SyncLocalStateStore(url: SyncLocalStateStore.defaultURL())
        )
        engine.onStatus = { [weak self] engineStatus in
            switch engineStatus {
            case .synced(let date): self?.status = .synced(date)
            case .failed(let date, let message): self?.status = .failed(date, message)
            }
        }
        self.engine = engine
        status = .waitingFirstSync
        engine.start()
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
    }
}
