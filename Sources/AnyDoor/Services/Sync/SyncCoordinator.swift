import AppKit
import Foundation
import Observation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "sync")

/// Which transport carries the sync state. Raw values are persisted in
/// `SyncDefaultsKeys.transport`.
enum SyncTransportKind: String, CaseIterable, Sendable {
    case folder
    case webdav
}

/// Owns the optional `SyncEngine` and the user-facing sync state the Settings
/// UI binds to. Enable/disable and transport changes take effect immediately —
/// no relaunch.
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
    @ObservationIgnored private let credentialStore: SyncWebDAVCredentialStore
    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private(set) var engine: SyncEngine?

    private(set) var status: Status = .idle
    private(set) var isEnabled = false
    private(set) var transportKind: SyncTransportKind
    private(set) var folderPath: String?
    private(set) var webdavURLString: String?
    private(set) var webdavUsername: String?

    init(
        defaults: UserDefaults = .standard,
        credentialStore: SyncWebDAVCredentialStore = SyncWebDAVCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        isEnabled = defaults.bool(forKey: SyncDefaultsKeys.enabled)
        transportKind = defaults.string(forKey: SyncDefaultsKeys.transport)
            .flatMap(SyncTransportKind.init) ?? .folder
        folderPath = defaults.string(forKey: SyncDefaultsKeys.folderPath)
        webdavURLString = defaults.string(forKey: SyncDefaultsKeys.webdavURL)
        webdavUsername = defaults.string(forKey: SyncDefaultsKeys.webdavUsername)
    }

    /// Called once at launch after the stores are seeded.
    func bootstrap(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        if isEnabled {
            startEngine()
        }
    }

    /// Point sync at a local folder (also the path for changing the folder
    /// while enabled — the engine is rebuilt on the new transport).
    func configureFolder(_ folderURL: URL) {
        defaults.set(SyncTransportKind.folder.rawValue, forKey: SyncDefaultsKeys.transport)
        defaults.set(folderURL.path, forKey: SyncDefaultsKeys.folderPath)
        transportKind = .folder
        folderPath = folderURL.path
        enable()
    }

    /// Point sync at a WebDAV directory. Returns false (and reports
    /// `.invalidConfiguration`) without enabling when the URL is not https
    /// (loopback http excepted) or the username is empty.
    @discardableResult
    func configureWebDAV(urlString: String, username: String, password: String) -> Bool {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL),
              Self.isAcceptableWebDAVURL(url),
              !trimmedUser.isEmpty
        else {
            status = .failed(Date(), .invalidConfiguration)
            return false
        }
        defaults.set(SyncTransportKind.webdav.rawValue, forKey: SyncDefaultsKeys.transport)
        defaults.set(url.absoluteString, forKey: SyncDefaultsKeys.webdavURL)
        defaults.set(trimmedUser, forKey: SyncDefaultsKeys.webdavUsername)
        // An empty password field means "keep the stored one" so re-saving
        // the URL doesn't force retyping the secret.
        if !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            credentialStore.setPassword(password)
        }
        transportKind = .webdav
        webdavURLString = url.absoluteString
        webdavUsername = trimmedUser
        enable()
        return true
    }

    /// Enable sync with the stored configuration.
    func enable() {
        defaults.set(true, forKey: SyncDefaultsKeys.enabled)
        isEnabled = true
        stopEngine()
        startEngine()
    }

    /// Disable sync. Local config, the machine's state file at the sync
    /// location, and the persisted local document all stay — re-enabling
    /// resumes.
    func disable() {
        defaults.set(false, forKey: SyncDefaultsKeys.enabled)
        isEnabled = false
        stopEngine()
        status = .idle
    }

    private func startEngine() {
        guard let modelContainer else { return }
        let built: (transport: any SyncTransport, pollInterval: TimeInterval)
        switch transportKind {
        case .folder:
            guard let transport = makeFolderTransport() else { return }
            // FSEvents carries change notice; the poll is only a safety net.
            built = (transport, 15 * 60)
        case .webdav:
            guard let transport = makeWebDAVTransport() else { return }
            // No change channel on WebDAV — polling is the convergence path.
            built = (transport, 90)
        }
        let engine = SyncEngine(
            config: SyncEngine.Configuration(
                deviceID: SyncEngine.ensuredDeviceID(in: defaults),
                deviceName: Host.current().localizedName,
                periodicInterval: built.pollInterval
            ),
            context: modelContainer.mainContext,
            defaults: defaults,
            transport: built.transport,
            stateStore: SyncLocalStateStore(url: SyncLocalStateStore.defaultURL())
        )
        engine.onStatus = { [weak self] engineStatus in
            switch engineStatus {
            case .synced(let date): self?.status = .synced(date)
            case .failed(let date, let reason): self?.status = .failed(date, reason)
            }
        }
        self.engine = engine
        status = .waitingFirstSync
        engine.start()
    }

    /// Basic-auth credentials must not travel over the open network, so the
    /// server URL must be https — except loopback hosts, which browsers
    /// likewise treat as a secure context (lets a local dev/test server run
    /// without TLS).
    static func isAcceptableWebDAVURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return host == "localhost" || host == "::1" || host.hasPrefix("127.")
        default: return false
        }
    }

    private func makeFolderTransport() -> (any SyncTransport)? {
        guard let path = folderPath else {
            status = .failed(Date(), .folderMissing)
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            logger.warning("sync folder missing, engine not started: \(path)")
            status = .failed(Date(), .folderMissing)
            return nil
        }
        return SyncFolderTransport(folderURL: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func makeWebDAVTransport() -> (any SyncTransport)? {
        guard let urlString = webdavURLString,
              let url = URL(string: urlString),
              let username = webdavUsername,
              let password = credentialStore.password()
        else {
            status = .failed(Date(), .invalidConfiguration)
            return nil
        }
        return SyncWebDAVTransport(
            config: SyncWebDAVConfiguration(baseURL: url, username: username, password: password)
        )
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
    }
}
