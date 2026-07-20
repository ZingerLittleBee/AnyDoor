import Foundation
import PluginInterface
import SwiftData
import OSLog
import Observation

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "hosts")

/// Errors originating in HostsManager itself (as opposed to the writer/backup).
enum HostsManagerError: Error {
    /// Reading the live `/etc/hosts` failed, so we cannot safely compose or write.
    case liveReadFailed
}

/// Single source of truth for host profiles. SwiftData-backed, @MainActor.
/// Persisted state always equals what was successfully applied to the system.
@Observable @MainActor
final class HostsManager {
    static func makeDefault(host: PluginHostContext) -> HostsManager {
        HostsManager(
            makeWriter: {
                // Re-evaluate on every write so the privileged helper is used as soon
                // as the user approves it — without requiring an app relaunch.
                if host.helperReadiness() == .enabled {
                    return PrivilegedHostsWriter(host: host)
                }
                return AppleScriptWriter(host: host)
            },
            backup: HostsBackupStore.makeDefault(),
            readLiveHosts: {
                try String(
                    contentsOf: URL(fileURLWithPath: "/etc/hosts"),
                    encoding: .utf8
                )
            },
            host: host
        )
    }

    private(set) var profiles: [HostProfile] = []
    /// System content (prefix + suffix) shown read-only in the UI.
    private(set) var systemHosts: String = ""
    private(set) var lastError: String?

    // MARK: - Writer factory (re-evaluated per write so helper approval takes effect immediately)
    private let makeWriter: () -> HostsWriter
    // `var` so tests can inject backupErrorOverride on the value-type HostsBackupStore.
    var backup: HostsBackupStore
    // Throwing: a failed read of `/etc/hosts` must abort composing/applying, never
    // fall back to an empty string (which would destroy the system's own entries).
    private let readLiveHosts: () throws -> String
    private let host: PluginHostContext?
    private var modelContainer: ModelContainer?

    // MARK: - Debounce / serialization state
    private let debounceInterval: Duration
    private var acceptsMutations = false
    private var applyPending = false
    private var applyTask: Task<Void, Never>?
    private var activeDirectOperations = 0
    private var operationDrainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Result of the most recent `applyAndPersist`; read by callers that must act
    /// only on a successful system write (e.g. `deleteProfile`).
    private var lastApplySucceeded = false

    // MARK: - Init

    /// Designated initialiser. Accepts a factory so the writer can be re-resolved per write.
    init(makeWriter: @escaping () -> HostsWriter,
         backup: HostsBackupStore,
         readLiveHosts: @escaping () throws -> String,
         debounceInterval: Duration = .milliseconds(150),
         host: PluginHostContext? = nil) {
        self.makeWriter = makeWriter
        self.backup = backup
        self.readLiveHosts = readLiveHosts
        self.debounceInterval = debounceInterval
        self.host = host
    }

    /// Convenience initialiser for tests that supply a fixed writer.
    convenience init(writer: HostsWriter,
                     backup: HostsBackupStore,
                     readLiveHosts: @escaping () throws -> String,
                     debounceInterval: Duration = .milliseconds(150),
                     host: PluginHostContext? = nil) {
        self.init(makeWriter: { writer }, backup: backup, readLiveHosts: readLiveHosts,
                  debounceInterval: debounceInterval, host: host)
    }

    func bootstrap(modelContainer: ModelContainer) {
        // Helper registration is an install-time act and lives in
        // `HostsNativePlugin.activate()` — bootstrap only wires the store.
        self.modelContainer = modelContainer
        acceptsMutations = true
        reload()
    }

    /// Stop accepting mutations, cancel work that has not reached the writer,
    /// and wait for any already-started system write to finish. A write that
    /// crossed the external boundary is drained instead of abandoned so the
    /// persisted profile state can still match `/etc/hosts`.
    func prepareForDeactivation() async {
        acceptsMutations = false
        applyPending = false
        lastApplySucceeded = false

        let pendingApply = applyTask
        pendingApply?.cancel()
        await pendingApply?.value

        await waitForDirectOperationsToDrain()

        if modelContainer?.mainContext.hasChanges == true {
            modelContainer?.mainContext.rollback()
            reload()
        }
    }

    /// A failed transactional uninstall leaves the plugin installed, so its
    /// manager must accept mutations again without requiring a reinstall.
    func resumeAfterFailedDeactivation() {
        acceptsMutations = true
    }

    func reload() {
        guard let context = modelContainer?.mainContext else { return }
        profiles = (try? context.fetch(
            FetchDescriptor<HostProfile>(sortBy: [SortDescriptor(\.displayOrder)])
        )) ?? []
        // Display-only: if the live read fails, keep the previously shown system
        // content rather than blanking it. The apply path handles read failures
        // via `HostsManagerError.liveReadFailed`.
        guard let live = try? readLiveHosts() else { return }
        let parsed = HostsFile.parse(live)
        systemHosts = [parsed.prefix, parsed.suffix]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func refresh() { reload() }

    // MARK: - Mutations

    func createProfile(name: String, content: String = "") {
        guard acceptsMutations, let context = modelContainer?.mainContext else { return }
        let nextOrder = (profiles.map(\.displayOrder).max() ?? 0) + 100
        context.insert(HostProfile(name: name, content: content, displayOrder: nextOrder))
        try? context.save()
        reload()
    }

    @discardableResult
    func duplicateProfile(_ profile: HostProfile) -> HostProfile? {
        guard acceptsMutations, let context = modelContainer?.mainContext else { return nil }
        let nextOrder = (profiles.map(\.displayOrder).max() ?? 0) + 100
        let duplicate = HostProfile(
            name: copyName(for: profile.name),
            content: profile.content,
            isActive: false,
            displayOrder: nextOrder
        )
        context.insert(duplicate)
        try? context.save()
        reload()
        return profiles.first { $0.id == duplicate.id }
    }

    /// Delete a profile. For an active profile the invariant "persisted state
    /// equals what was applied" must hold: remove its managed block from the
    /// system first and only drop the DB row once that write succeeds, so a
    /// failed write leaves the row (and its block) intact instead of orphaning it.
    func deleteProfile(_ profile: HostProfile) async {
        guard acceptsMutations, let context = modelContainer?.mainContext else { return }
        if profile.isActive {
            // Deactivate in memory and apply; the row is only deleted on success.
            profile.isActive = false
            let applied = await scheduleApply()
            guard acceptsMutations else { return }
            // scheduleApply coalesces concurrent callers into one task and returns
            // the shared last-iteration result, so its Bool alone can report a
            // batch-mate's success — including a no-op retry after a failed write
            // whose rollback() restored `isActive` to true. Gate the irreversible
            // delete on the fact that matters: this profile's deactivation was
            // actually applied and saved (`isActive` stayed false).
            guard applied, !profile.isActive else {
                if lastError == nil { lastError = L(host, .hostsErrorDeleteFailed) }
                return
            }
        }
        context.delete(profile)
        try? context.save()
        reload()
    }

    private func copyName(for name: String) -> String {
        let base = L(host, .hostsProfileCopyName, name)
        let existing = Set(profiles.map(\.name))
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    /// Edit a profile. Persists immediately; re-applies only if active.
    func updateProfile(_ profile: HostProfile, name: String, content: String) async {
        guard acceptsMutations else { return }
        profile.name = name
        profile.content = content
        profile.updatedAt = Date()
        if profile.isActive {
            await scheduleApply()
        } else {
            try? modelContainer?.mainContext.save()
            reload()
        }
    }

    /// Toggle activation. Applies first; persists only on success.
    func setActive(_ profile: HostProfile, _ active: Bool) async {
        guard acceptsMutations else { return }
        profile.isActive = active
        await scheduleApply()
    }

    /// Edit the system portion of `/etc/hosts` in place. The edited content
    /// becomes the new prefix; AnyDoor's managed block (active profiles) is
    /// re-appended so user profiles survive a system-hosts edit.
    func updateSystemHosts(_ newContent: String) async {
        guard acceptsMutations else { return }
        // Serialize against any in-flight composed apply.
        await applyTask?.value
        guard beginDirectOperation() else { return }
        defer { endDirectOperation() }

        var backupError: Error?
        do {
            try backup.ensureOriginalBackup()
        } catch {
            backupError = error
            logger.warning("Backup creation failed: \(error)")
        }
        do {
            try await applyContent(composedContent(systemPrefix: newContent))
            lastError = backupError != nil ? L(host, .hostsErrorBackupFailed) : nil
            reload()
        } catch {
            lastError = message(for: error)
            logger.error("System hosts edit failed: \(error)")
            reload()
        }
    }

    /// Destructive restore (UI must confirm): overwrite with first-run backup.
    func restoreFirstRunBackup() async {
        guard acceptsMutations else { return }
        // Wait for any in-flight composed apply to finish before overwriting.
        await applyTask?.value
        guard beginDirectOperation() else { return }
        defer { endDirectOperation() }

        guard let original = backup.originalContents() else {
            lastError = L(host, .hostsErrorNoBackup)
            return
        }
        do {
            let writer = makeWriter()
            try await writer.write(original)
            for p in profiles { p.isActive = false }
            try? modelContainer?.mainContext.save()
            reload()
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Debounce / serialize

    /// Coalescing debounced entry-point for composed applies. All callers that
    /// go through the compose path use this instead of `applyAndPersist` directly.
    @discardableResult
    private func scheduleApply() async -> Bool {
        guard acceptsMutations else { return false }
        applyPending = true
        if applyTask == nil {
            applyTask = Task { @MainActor in
                defer { self.applyTask = nil }
                do {
                    try await Task.sleep(for: self.debounceInterval)
                    try Task.checkCancellation()
                } catch {
                    self.applyPending = false
                    self.lastApplySucceeded = false
                    return
                }
                // Serial retry loop: pick up any toggle that arrived during the write.
                while self.applyPending && self.acceptsMutations && !Task.isCancelled {
                    self.applyPending = false
                    self.lastApplySucceeded = await self.applyAndPersist()
                }
            }
        }
        await applyTask?.value
        return lastApplySucceeded
    }

    private func beginDirectOperation() -> Bool {
        guard acceptsMutations else { return false }
        activeDirectOperations += 1
        return true
    }

    private func endDirectOperation() {
        activeDirectOperations -= 1
        guard activeDirectOperations == 0 else { return }
        let waiters = operationDrainWaiters
        operationDrainWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForDirectOperationsToDrain() async {
        guard activeDirectOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            operationDrainWaiters.append(continuation)
        }
    }

    // MARK: - Apply

    /// Returns `true` when the compose+write+persist succeeded (including a no-op
    /// skip), `false` when the write failed and the context was rolled back.
    private func applyAndPersist() async -> Bool {
        // Capture backup error; a failed backup must not abort the write.
        var backupError: Error?
        do {
            try backup.ensureOriginalBackup()
        } catch {
            backupError = error
            logger.warning("Backup creation failed: \(error)")
        }

        do {
            try await applyContent(composedContent(systemPrefix: nil))
            try? modelContainer?.mainContext.save()
            // Surface backup warning instead of clearing error on success.
            if let _ = backupError {
                lastError = L(host, .hostsErrorBackupFailed)
            } else {
                lastError = nil
            }
            reload()
            return true
        } catch {
            // Discard unsaved in-memory mutations so reload() sees the persisted state.
            modelContainer?.mainContext.rollback()
            lastError = message(for: error)
            logger.error("Apply failed: \(error)")
            reload()
            return false
        }
    }

    /// Build the full `/etc/hosts` text. When `systemPrefix` is nil the existing
    /// system content is preserved from the live file; otherwise it is replaced
    /// (used by `updateSystemHosts`). The managed block is always rebuilt from
    /// the currently active profiles.
    private func composedContent(systemPrefix: String?) throws -> String {
        let parsed: HostsFile.Parsed
        if let systemPrefix {
            parsed = HostsFile.Parsed(prefix: systemPrefix, managed: nil, suffix: "")
        } else {
            parsed = HostsFile.parse(try readLive())
        }
        let active = profiles
            .filter(\.isActive)
            .sorted { $0.displayOrder < $1.displayOrder }
            .map { (name: $0.name, content: $0.content) }
        return HostsFile.compose(parsed: parsed, activeProfiles: active)
    }

    /// Write `content` through the current writer, skipping the privileged write
    /// entirely when it would not change the file (e.g. toggling or deleting a
    /// blank profile) so the user is never prompted for a no-op.
    private func applyContent(_ content: String) async throws {
        guard content != (try readLive()) else { return }
        let writer = makeWriter()
        try await writer.write(content)
    }

    /// Read the live `/etc/hosts`, mapping any failure to `liveReadFailed` so
    /// compose/apply abort with a user-facing Chinese message instead of writing
    /// against a bogus empty baseline.
    private func readLive() throws -> String {
        do {
            return try readLiveHosts()
        } catch {
            logger.error("Reading /etc/hosts failed: \(error)")
            throw HostsManagerError.liveReadFailed
        }
    }

    /// Map known manager errors to localized UI text; everything else falls
    /// back to the writer's description.
    private func message(for error: Error) -> String {
        if let error = error as? HostsManagerError {
            switch error {
            case .liveReadFailed:
                return L(host, .hostsErrorLiveReadFailed)
            }
        }
        return String(describing: error)
    }
}
