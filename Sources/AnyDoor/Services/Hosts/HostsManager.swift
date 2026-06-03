import Foundation
import SwiftData
import OSLog
import Observation

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "hosts")

/// Single source of truth for host profiles. SwiftData-backed, @MainActor.
/// Persisted state always equals what was successfully applied to the system.
@Observable @MainActor
final class HostsManager {
    static let shared = HostsManager(
        makeWriter: {
            // Re-evaluate on every write so the privileged helper is used as soon
            // as the user approves it — without requiring an app relaunch.
            if HelperManager.shared.readiness() == .enabled {
                return PrivilegedHelperWriter()
            }
            return AppleScriptWriter()
        },
        backup: HostsBackupStore.makeDefault(),
        readLiveHosts: { (try? String(contentsOf: URL(fileURLWithPath: "/etc/hosts"), encoding: .utf8)) ?? "" }
    )

    private(set) var profiles: [HostProfile] = []
    /// System content (prefix + suffix) shown read-only in the UI.
    private(set) var systemHosts: String = ""
    private(set) var lastError: String?

    // MARK: - Writer factory (re-evaluated per write so helper approval takes effect immediately)
    private let makeWriter: () -> HostsWriter
    // `var` so tests can inject backupErrorOverride on the value-type HostsBackupStore.
    var backup: HostsBackupStore
    private let readLiveHosts: () -> String
    private var modelContainer: ModelContainer?

    // MARK: - Debounce / serialization state
    private let debounceInterval: Duration
    private var applyPending = false
    private var applyTask: Task<Void, Never>?

    // MARK: - Init

    /// Designated initialiser. Accepts a factory so the writer can be re-resolved per write.
    init(makeWriter: @escaping () -> HostsWriter,
         backup: HostsBackupStore,
         readLiveHosts: @escaping () -> String,
         debounceInterval: Duration = .milliseconds(150)) {
        self.makeWriter = makeWriter
        self.backup = backup
        self.readLiveHosts = readLiveHosts
        self.debounceInterval = debounceInterval
    }

    /// Convenience initialiser for tests that supply a fixed writer.
    convenience init(writer: HostsWriter,
                     backup: HostsBackupStore,
                     readLiveHosts: @escaping () -> String,
                     debounceInterval: Duration = .milliseconds(150)) {
        self.init(makeWriter: { writer }, backup: backup, readLiveHosts: readLiveHosts,
                  debounceInterval: debounceInterval)
    }

    func bootstrap(modelContainer: ModelContainer) {
        // Attempt helper registration once at startup (cheap; falls through if already registered).
        _ = HelperManager.shared.ensureRegistered()
        self.modelContainer = modelContainer
        reload()
    }

    func reload() {
        guard let context = modelContainer?.mainContext else { return }
        profiles = (try? context.fetch(
            FetchDescriptor<HostProfile>(sortBy: [SortDescriptor(\.displayOrder)])
        )) ?? []
        let parsed = HostsFile.parse(readLiveHosts())
        systemHosts = [parsed.prefix, parsed.suffix]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func refresh() { reload() }

    // MARK: - Mutations

    func createProfile(name: String, content: String = "") {
        guard let context = modelContainer?.mainContext else { return }
        let nextOrder = (profiles.map(\.displayOrder).max() ?? 0) + 100
        context.insert(HostProfile(name: name, content: content, displayOrder: nextOrder))
        try? context.save()
        reload()
    }

    func deleteProfile(_ profile: HostProfile) async {
        guard let context = modelContainer?.mainContext else { return }
        let wasActive = profile.isActive
        context.delete(profile)
        try? context.save()
        reload()
        if wasActive { await scheduleApply() }
    }

    /// Edit a profile. Persists immediately; re-applies only if active.
    func updateProfile(_ profile: HostProfile, name: String, content: String) async {
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
        profile.isActive = active
        await scheduleApply()
    }

    /// DEFAULT safe restore: remove only AnyDoor's managed block.
    func removeManagedBlock() async {
        for p in profiles { p.isActive = false }
        await scheduleApply()
    }

    /// Destructive restore (UI must confirm): overwrite with first-run backup.
    func restoreFirstRunBackup() async {
        // Wait for any in-flight composed apply to finish before overwriting.
        await applyTask?.value

        guard let original = backup.originalContents() else {
            lastError = "无可用备份"
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
    private func scheduleApply() async {
        applyPending = true
        if applyTask == nil {
            applyTask = Task { @MainActor in
                try? await Task.sleep(for: self.debounceInterval)
                // Serial retry loop: pick up any toggle that arrived during the write.
                while self.applyPending {
                    self.applyPending = false
                    await self.applyAndPersist()
                }
                self.applyTask = nil
            }
        }
        await applyTask?.value
    }

    // MARK: - Apply

    private func applyAndPersist() async {
        // Capture backup error; a failed backup must not abort the write.
        var backupError: Error?
        do {
            try backup.ensureOriginalBackup()
        } catch {
            backupError = error
            logger.warning("Backup creation failed: \(error)")
        }

        do {
            try await applyToSystemThrowing()
            try? modelContainer?.mainContext.save()
            // Surface backup warning instead of clearing error on success.
            if let _ = backupError {
                lastError = "备份创建失败，可能无法完整恢复"
            } else {
                lastError = nil
            }
            reload()
        } catch {
            // Discard unsaved in-memory mutations so reload() sees the persisted state.
            modelContainer?.mainContext.rollback()
            lastError = String(describing: error)
            logger.error("Apply failed: \(error)")
            reload()
        }
    }

    private func applyToSystemThrowing() async throws {
        let writer = makeWriter()
        let parsed = HostsFile.parse(readLiveHosts())
        let active = profiles
            .filter(\.isActive)
            .sorted { $0.displayOrder < $1.displayOrder }
            .map { (name: $0.name, content: $0.content) }
        let newContent = HostsFile.compose(parsed: parsed, activeProfiles: active)
        try await writer.write(newContent)
    }
}
