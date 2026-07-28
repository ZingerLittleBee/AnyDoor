import AppKit
import Foundation
import OSLog
import PluginInterface
import SwiftData

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "sync")

extension Notification.Name {
    /// Posted by the SwiftData mutation funnels (PanelStore, QuicklinkStore,
    /// BackupService restore) after saving portable configuration. Settings
    /// changes are covered separately by `UserDefaults.didChangeNotification`.
    static let portableConfigDidChange = Notification.Name("dev.bybee.AnyDoor.portableConfigDidChange")
}

/// Machine-local defaults keys configuring sync. Deliberately not in
/// `SyncSettingsRegistry` — the sync configuration itself never travels.
/// The WebDAV password lives in the Keychain (`SyncWebDAVCredentialStore`),
/// never here.
enum SyncDefaultsKeys {
    static let enabled = "sync.enabled"
    static let transport = "sync.transport"
    static let folderPath = "sync.folderPath"
    static let webdavURL = "sync.webdav.url"
    static let webdavUsername = "sync.webdav.username"
    static let deviceID = "sync.deviceID"
}

/// Why a tick (or engine start) failed, for the Settings status line. An enum
/// so the UI layer owns the localized wording.
enum SyncFailureReason: Equatable, Sendable {
    case folderMissing
    case folderUnreachable
    case folderNotWritable
    case unauthorized
    case invalidConfiguration
    case applyFailed
}

/// Outcome of one tick, reported to the owner for the Settings status line.
enum SyncEngineStatus: Equatable, Sendable {
    case synced(Date)
    case failed(Date, SyncFailureReason)
}

/// The Config Sync engine (ADR-0010). Owns this machine's Sync Document and
/// drives the tick pipeline:
///
///   capture local changes → read peer state files → CRDT merge
///   → apply the merged document to local stores → persist → write own file
///
/// Change capture is diff-based: the current local content is compared with
/// the document's payloads; changed records are stamped with a fresh clock and
/// records that vanished locally become tombstones. This makes capture
/// idempotent (a converged state diffs to nothing), so echo loops from the
/// engine's own applies die out by themselves, and deletions need no explicit
/// reporting from the stores — a nudge that "something changed" is enough.
@MainActor
final class SyncEngine {
    struct Configuration {
        var deviceID: String
        var deviceName: String?
        var debounceInterval: TimeInterval = 10
        var periodicInterval: TimeInterval = 15 * 60
        var tombstoneRetentionMillis: Int64 = 90 * 24 * 3_600 * 1_000
    }

    private let config: Configuration
    private let context: ModelContext
    private let defaults: UserDefaults
    private let transport: any SyncTransport
    private let stateStore: SyncLocalStateStore
    private let appPathResolver: (String) -> String?
    private let reconcileRuntime: @MainActor () async throws -> Void
    private let wallNow: () -> Int64

    private var clock: SyncClock
    private(set) var document: SyncDocument
    private var lastWrittenData: Data?
    private var debounceGeneration = 0
    private var tickInFlight = false
    private var tickPending = false
    private var observers: [NSObjectProtocol] = []
    private var watcher: DirectoryWatcher?
    private var periodicTask: Task<Void, Never>?

    /// Set by the owner before `start()`; called after every tick.
    var onStatus: @MainActor (SyncEngineStatus) -> Void = { _ in }

    init(
        config: Configuration,
        context: ModelContext,
        defaults: UserDefaults,
        transport: any SyncTransport,
        stateStore: SyncLocalStateStore,
        appPathResolver: @escaping (String) -> String? = { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        },
        reconcileRuntime: @escaping @MainActor () async throws -> Void = {
            try await BackupService.reconcileLiveRuntime()
        },
        wallNow: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) {
        self.config = config
        self.context = context
        self.defaults = defaults
        self.transport = transport
        self.stateStore = stateStore
        self.appPathResolver = appPathResolver
        self.reconcileRuntime = reconcileRuntime
        self.wallNow = wallNow

        if let persisted = stateStore.load(), persisted.clock.deviceID == config.deviceID {
            clock = persisted.clock
            document = persisted.document
        } else {
            clock = SyncClock(deviceID: config.deviceID)
            document = SyncDocument(deviceID: config.deviceID, deviceName: config.deviceName)
        }
        document.deviceName = config.deviceName
    }

    // MARK: - Lifecycle

    static func ensuredDeviceID(in defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: SyncDefaultsKeys.deviceID) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: SyncDefaultsKeys.deviceID)
        return fresh
    }

    /// Register triggers and run the initial tick.
    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .portableConfigDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.noteLocalChange() }
        })
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.noteLocalChange() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tickSoon() }
        })
        if let directory = transport.watchableDirectory {
            watcher = DirectoryWatcher(directory: directory, debounce: 2) { [weak self] in
                self?.tickSoon()
            }
        }
        let interval = config.periodicInterval
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
        tickSoon()
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
        watcher?.cancel()
        watcher = nil
        periodicTask?.cancel()
        periodicTask = nil
        debounceGeneration += 1
    }

    // MARK: - Triggers

    /// Debounced full tick; config edits are bursty (drags, reorders).
    func noteLocalChange() {
        debounceGeneration += 1
        let generation = debounceGeneration
        let delay = config.debounceInterval
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.debounceGeneration == generation else { return }
            await self.tick()
        }
    }

    private func tickSoon() {
        Task { @MainActor in await self.tick() }
    }

    // MARK: - Tick pipeline

    func tick() async {
        if tickInFlight {
            tickPending = true
            return
        }
        tickInFlight = true
        defer {
            tickInFlight = false
            if tickPending {
                tickPending = false
                tickSoon()
            }
        }

        // Capture first, so the document is a superset of local state before
        // it becomes authoritative in apply.
        captureLocalChanges()

        var failure: SyncFailureReason?
        var peers: [SyncDocument] = []
        do {
            peers = try await transport.readPeerDocuments(excludingDeviceID: config.deviceID)
        } catch {
            logger.warning("sync peer listing failed: \(error)")
            failure = (error as? SyncTransportError) == .unauthorized
                ? .unauthorized : .folderUnreachable
        }
        var merged = document
        for peer in peers {
            merged = merged.merged(with: peer)
        }
        for entry in merged.entries.values {
            clock.observe(entry.clock)
        }

        let entriesChanged = merged.entries != document.entries
        document = merged
        if entriesChanged {
            do {
                if try applyDocument() {
                    try await reconcileRuntime()
                }
            } catch {
                logger.error("sync apply failed: \(error)")
                failure = failure ?? .applyFailed
            }
        }

        document = document.prunedTombstones(
            before: wallNow() - config.tombstoneRetentionMillis
        )
        persistState()
        if let writeFailure = await writeOwnDocumentIfNeeded() {
            failure = failure ?? writeFailure
        }
        onStatus(failure.map { .failed(Date(), $0) } ?? .synced(Date()))
    }

    // MARK: - Change capture

    /// Diff current local content against the document; stamp changes, and
    /// tombstone records that vanished locally. Only records this build can
    /// own are ever tombstoned — an entry from a newer app version (unknown
    /// setting key, unknown builtin) is carried untouched, never deleted.
    func captureLocalChanges() {
        let payloads = SyncSnapshotMapping.payloads(from: readLocalContent())
        var changed = false
        for (key, payload) in payloads where document.entries[key]?.payload != payload {
            document.entries[key] = SyncEntry(
                payload: payload,
                clock: clock.now(wallMillis: wallNow())
            )
            changed = true
        }
        for (key, entry) in document.entries
        where !entry.isTombstone && payloads[key] == nil && canOwn(key) {
            document.entries[key] = SyncEntry(
                payload: nil,
                clock: clock.now(wallMillis: wallNow())
            )
            changed = true
        }
        if changed {
            persistState()
        }
    }

    private func readLocalContent() -> SyncSnapshotMapping.Content {
        let bindings = (try? context.fetch(FetchDescriptor<KeyBinding>())) ?? []
        let prefs = (try? context.fetch(FetchDescriptor<BuiltinPreference>())) ?? []
        let quicklinks = (try? context.fetch(FetchDescriptor<Quicklink>())) ?? []
        return SyncSnapshotMapping.Content(
            appShortcuts: bindings.map(AppShortcutDTO.init),
            builtinPreferences: prefs
                .filter { BuiltinItem(rawValue: $0.itemKey) != nil }
                .map(BuiltinPreferenceDTO.init),
            quicklinks: quicklinks.map(QuicklinkDTO.init),
            settings: SyncSettingsRegistry.read(from: defaults)
        )
    }

    private func canOwn(_ key: SyncKey) -> Bool {
        switch key {
        case .appShortcut, .quicklink:
            return true
        case .builtinPreference(let itemKey):
            return BuiltinItem(rawValue: itemKey) != nil
        case .setting(let settingKey):
            return SyncSettingsRegistry.contains(settingKey)
        }
    }

    // MARK: - Apply (document → local stores)

    /// Make local state match the document for every record this build owns.
    /// Returns whether anything actually changed (callers reconcile the live
    /// runtime only then).
    private func applyDocument() throws -> Bool {
        let owned = document.entries.filter { canOwn($0.key) }
        let target = SyncSnapshotMapping.content(from: owned)
        var dirty = false

        dirty = try applyAppShortcuts(target.appShortcuts) || dirty
        dirty = try applyBuiltinPreferences(target.builtinPreferences) || dirty
        dirty = try applyQuicklinks(target.quicklinks, owned: owned) || dirty
        let settingsDirty = applySettings(owned: owned)

        if dirty {
            try context.save()
        }
        return dirty || settingsDirty
    }

    private func applyAppShortcuts(_ target: [AppShortcutDTO]) throws -> Bool {
        var dirty = false
        let rows = try context.fetch(FetchDescriptor<KeyBinding>())
        let rowsByBundleID = Dictionary(
            rows.map { ($0.appBundleID, $0) },
            uniquingKeysWith: { _, last in last }
        )
        var targetBundleIDs = Set<String>()
        for dto in target {
            targetBundleIDs.insert(dto.appBundleID)
            if let row = rowsByBundleID[dto.appBundleID] {
                guard AppShortcutDTO(row) != dto else { continue }
                row.appName = dto.appName
                row.keyCode = dto.keyCode
                row.modifierFlags = dto.modifierFlags
                row.isEnabled = dto.isEnabled
                row.isVisible = dto.isVisible
                row.displayOrder = dto.displayOrder
                row.appPath = appPathResolver(dto.appBundleID) ?? ""
                dirty = true
            } else {
                context.insert(KeyBinding(
                    keyCode: dto.keyCode, modifierFlags: dto.modifierFlags,
                    appBundleID: dto.appBundleID, appName: dto.appName,
                    appPath: appPathResolver(dto.appBundleID) ?? "",
                    isEnabled: dto.isEnabled, isVisible: dto.isVisible,
                    displayOrder: dto.displayOrder
                ))
                dirty = true
            }
        }
        // Capture ran first, so every local row has a live document entry
        // unless it was tombstoned remotely — those get deleted here.
        for row in rows where !targetBundleIDs.contains(row.appBundleID) {
            context.delete(row)
            dirty = true
        }
        return dirty
    }

    /// Preference rows are created by the seeder and never deleted; sync only
    /// updates known rows.
    private func applyBuiltinPreferences(_ target: [BuiltinPreferenceDTO]) throws -> Bool {
        var dirty = false
        let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
        let rowsByKey = Dictionary(
            rows.map { ($0.itemKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for dto in target {
            guard let row = rowsByKey[dto.itemKey],
                  BuiltinPreferenceDTO(row) != dto else { continue }
            row.isVisible = dto.isVisible
            row.displayOrder = dto.displayOrder
            row.keyCode = dto.keyCode
            row.modifierFlags = dto.modifierFlags
            dirty = true
        }
        return dirty
    }

    private func applyQuicklinks(
        _ target: [QuicklinkDTO],
        owned: [SyncKey: SyncEntry]
    ) throws -> Bool {
        var dirty = false

        // Keyword uniqueness across concurrently-created rows: every machine
        // resolves collisions the same way (newest entry clock keeps the
        // keyword), then the next capture propagates the clearing.
        var keywordOwner: [String: UUID] = [:]
        for dto in target {
            guard let keyword = normalizedKeyword(dto.keyword) else { continue }
            if let current = keywordOwner[keyword] {
                let currentClock = owned[.quicklink(id: current)]?.clock
                let candidateClock = owned[.quicklink(id: dto.id)]?.clock
                if let currentClock, let candidateClock, currentClock < candidateClock {
                    keywordOwner[keyword] = dto.id
                }
            } else {
                keywordOwner[keyword] = dto.id
            }
        }

        let rows = try context.fetch(FetchDescriptor<Quicklink>())
        let rowsByID = Dictionary(
            rows.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        var targetIDs = Set<UUID>()
        for var dto in target {
            if let keyword = normalizedKeyword(dto.keyword), keywordOwner[keyword] != dto.id {
                dto.keyword = nil
            }
            targetIDs.insert(dto.id)
            if let row = rowsByID[dto.id] {
                guard QuicklinkDTO(row) != dto else { continue }
                row.name = dto.name
                row.keyword = dto.keyword
                row.link = dto.link
                row.openWithBundleID = QuicklinkOpenWith.normalizedBundleID(dto.openWithBundleID)
                row.keyCode = dto.keyCode
                row.modifierFlags = dto.modifierFlags
                row.isVisible = dto.isVisible
                row.displayOrder = dto.displayOrder
                row.createdAt = dto.createdAt
                dirty = true
            } else {
                context.insert(Quicklink(
                    id: dto.id,
                    name: dto.name,
                    keyword: dto.keyword,
                    link: dto.link,
                    openWithBundleID: QuicklinkOpenWith.normalizedBundleID(dto.openWithBundleID),
                    keyCode: dto.keyCode,
                    modifierFlags: dto.modifierFlags,
                    isVisible: dto.isVisible,
                    displayOrder: dto.displayOrder,
                    createdAt: dto.createdAt
                ))
                dirty = true
            }
        }
        for row in rows where !targetIDs.contains(row.id) {
            context.delete(row)
            dirty = true
        }
        return dirty
    }

    private func applySettings(owned: [SyncKey: SyncEntry]) -> Bool {
        var dirty = false
        let current = SyncSettingsRegistry.read(from: defaults)
        for (key, entry) in owned {
            guard case .setting(let settingKey) = key else { continue }
            if entry.isTombstone {
                if defaults.object(forKey: settingKey) != nil {
                    defaults.removeObject(forKey: settingKey)
                    dirty = true
                }
            } else if case .setting(let value) = entry.payload, current[settingKey] != value {
                if SyncSettingsRegistry.write([settingKey: value], to: defaults) > 0 {
                    dirty = true
                }
            }
        }
        return dirty
    }

    private func normalizedKeyword(_ keyword: String?) -> String? {
        guard let trimmed = keyword?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    // MARK: - Persistence

    private func persistState() {
        do {
            try stateStore.save(SyncLocalState(clock: clock, document: document))
        } catch {
            logger.error("persisting local sync state failed: \(error)")
        }
    }

    /// Returns a failure reason, nil on success or no-op.
    private func writeOwnDocumentIfNeeded() async -> SyncFailureReason? {
        do {
            let data = try SyncStateCodec.encode(document)
            guard data != lastWrittenData else { return nil }
            try await transport.writeOwnDocument(data, deviceID: config.deviceID)
            lastWrittenData = data
            return nil
        } catch {
            logger.warning("writing own sync state failed: \(error)")
            return (error as? SyncTransportError) == .unauthorized
                ? .unauthorized : .folderNotWritable
        }
    }
}
