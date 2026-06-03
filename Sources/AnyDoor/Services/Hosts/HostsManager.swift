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
        writer: HostsManager.makeDefaultWriter(),
        backup: HostsBackupStore.makeDefault(),
        readLiveHosts: { (try? String(contentsOf: URL(fileURLWithPath: "/etc/hosts"), encoding: .utf8)) ?? "" }
    )

    private(set) var profiles: [HostProfile] = []
    /// System content (prefix + suffix) shown read-only in the UI.
    private(set) var systemHosts: String = ""
    private(set) var lastError: String?

    private let writer: HostsWriter
    private let backup: HostsBackupStore
    private let readLiveHosts: () -> String
    private var modelContainer: ModelContainer?

    init(writer: HostsWriter, backup: HostsBackupStore, readLiveHosts: @escaping () -> String) {
        self.writer = writer
        self.backup = backup
        self.readLiveHosts = readLiveHosts
    }

    @MainActor
    private static func makeDefaultWriter() -> HostsWriter {
        if HelperManager.shared.ensureRegistered() {
            return PrivilegedHelperWriter()
        }
        return AppleScriptWriter()
    }

    func bootstrap(modelContainer: ModelContainer) {
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
        if wasActive { await applyToSystem() }
    }

    /// Edit a profile. Persists immediately; re-applies only if active.
    func updateProfile(_ profile: HostProfile, name: String, content: String) async {
        profile.name = name
        profile.content = content
        profile.updatedAt = Date()
        if profile.isActive {
            await applyAndPersist()
        } else {
            try? modelContainer?.mainContext.save()
            reload()
        }
    }

    /// Toggle activation. Applies first; persists only on success.
    func setActive(_ profile: HostProfile, _ active: Bool) async {
        let previous = profile.isActive
        profile.isActive = active
        await applyAndPersist(onFailureRollback: { profile.isActive = previous })
    }

    /// DEFAULT safe restore: remove only AnyDoor's managed block.
    func removeManagedBlock() async {
        for p in profiles { p.isActive = false }
        await applyAndPersist()
    }

    /// Destructive restore (UI must confirm): overwrite with first-run backup.
    func restoreFirstRunBackup() async {
        // Extract the backup content on the main actor before the async write,
        // avoiding a Swift 6 data-race when sending self.backup to nonisolated code.
        guard let original = backup.originalContents() else {
            lastError = "No backup available"
            return
        }
        do {
            try await writer.write(original)
            for p in profiles { p.isActive = false }
            try? modelContainer?.mainContext.save()
            reload()
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Apply

    private func applyAndPersist(onFailureRollback rollback: (() -> Void)? = nil) async {
        do {
            try? backup.ensureOriginalBackup()
            try await applyToSystemThrowing()
            try? modelContainer?.mainContext.save()
            lastError = nil
            reload()
        } catch {
            rollback?()
            lastError = String(describing: error)
            logger.error("Apply failed: \(error)")
            reload()
        }
    }

    /// Non-throwing convenience used by delete (state already persisted).
    private func applyToSystem() async {
        try? backup.ensureOriginalBackup()
        do { try await applyToSystemThrowing() } catch { lastError = String(describing: error) }
    }

    private func applyToSystemThrowing() async throws {
        let parsed = HostsFile.parse(readLiveHosts())
        let active = profiles
            .filter(\.isActive)
            .sorted { $0.displayOrder < $1.displayOrder }
            .map { (name: $0.name, content: $0.content) }
        let newContent = HostsFile.compose(parsed: parsed, activeProfiles: active)
        try await writer.write(newContent)
    }
}
