import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "plugins")

/// A plugin kind's hooks into the shared lifecycle machinery.
///
/// The lifecycle core (`PluginLifecycleCore`) speaks only in opaque plugin id
/// strings and generic lifecycle verbs — install state, activation ordering,
/// transactional uninstall, backup reconcile, palette recomposition. Everything
/// a specific plugin kind knows (which commands a Native Plugin claims, its
/// providers, its retained-hotkey conflicts) lives behind this delegate, so a
/// second plugin kind can share the same core by providing its own
/// implementation. The core never names a kind-specific concept.
///
/// The delegate is the kind's registry; the core holds it `unowned` because the
/// core's lifetime is contained within the registry's.
@MainActor
protocol AnyPluginLifecycleHost: AnyObject {
    /// The id strings of every plugin this kind knows about, in a stable order.
    /// The core intersects the persisted install set with this list and drives
    /// each lifecycle phase by iterating it, so the order fixes the order of
    /// activation, publication, and reconcile-failure reporting.
    func lifecyclePluginIDs() -> [String]

    /// Start install-scoped work for a plugin about to enter the installed set
    /// (called before it is marked installed, matching cold-launch ordering).
    func activateLifecyclePlugin(idString: String)

    /// Release the plugin's shared resources and cancel its in-flight work.
    /// A throw aborts the uninstall transactionally — the core reverses nothing
    /// because it has not yet mutated any state or surface.
    func deactivateLifecyclePlugin(idString: String) async throws

    /// Resolve any conflicts that must settle before a plugin is installed
    /// (Native Plugins re-resolve a retained hotkey rebound while absent).
    /// Runs before activation, against the pre-install available surface.
    func prepareLifecycleInstall(idString: String)

    /// Register the plugin's surfaces after it has entered the installed set
    /// and the state has been persisted.
    func registerLifecycleSurfaces(idString: String)

    /// Remove the plugin's surfaces after it has left the installed set and the
    /// state has been persisted.
    func unregisterLifecycleSurfaces(idString: String)

    /// Republish the kind's own surfaces (Native Plugins rebuild the panel and
    /// refresh hotkeys). The core republishes the shared command palette
    /// separately, so this hook covers only the kind-specific surfaces.
    func publishLifecycleSurfaces()

    /// Let a still-installed plugin re-read imported settings after a config
    /// backup import has converged its install state.
    func reconcileLifecycleImport(idString: String)

    /// The kind's typed error for a lifecycle transition already in flight for
    /// the same plugin (returned as an opaque `Error` the core rethrows/records).
    func lifecycleTransitionInProgressError(idString: String) -> any Error
}

/// A single reconcile failure surfaced back to the kind layer, pairing the
/// plugin id string with the opaque error the core caught for it. The kind
/// layer maps these into its own typed reconciliation error.
struct PluginLifecycleReconcileFailure {
    let idString: String
    let error: any Error
}

/// The kind-agnostic plugin lifecycle engine shared by every plugin kind.
///
/// Owns the install-state set and its persistence, the activate-before-installed
/// ordering, the transactional uninstall, the backup-import reconcile, and the
/// live command-palette recomposition. It never references a plugin kind's
/// concepts directly — all of that is reached through `AnyPluginLifecycleHost`.
/// Observation of `installedIDStrings` drives the Plugins settings UI, so this
/// type is `@Observable` and the kind registries read install state through it.
@MainActor
@Observable
final class PluginLifecycleCore {
    /// The installed plugin id strings. The single source of truth for install
    /// state; persisted verbatim to `installStateKey` as a sorted `[String]`.
    private(set) var installedIDStrings: Set<String> = []

    @ObservationIgnored private unowned let host: AnyPluginLifecycleHost
    @ObservationIgnored private let installStateKey: String
    @ObservationIgnored var defaults: UserDefaults
    /// Republishes the shared command palette from the live registrations of
    /// every kind. Kind-agnostic — it recomposes whatever contributions exist.
    @ObservationIgnored private let refreshCommandPalette: @MainActor () -> Void
    /// Re-entrancy guard: id strings with an uninstall's async deactivate in
    /// flight.
    @ObservationIgnored private var transitioningIDs: Set<String> = []

    init(
        host: AnyPluginLifecycleHost,
        installStateKey: String,
        defaults: UserDefaults = .standard,
        refreshCommandPalette: @escaping @MainActor () -> Void
    ) {
        self.host = host
        self.installStateKey = installStateKey
        self.defaults = defaults
        self.refreshCommandPalette = refreshCommandPalette
    }

    // MARK: - Install-state queries

    func contains(_ idString: String) -> Bool {
        installedIDStrings.contains(idString)
    }

    var transitioning: Set<String> {
        transitioningIDs
    }

    // MARK: - Bootstrap

    /// Read the persisted install set (keeping only ids the kind still knows),
    /// activate every installed plugin, and mark it installed — in the host's
    /// declared plugin order. Runtime state starts empty so cold-launch
    /// activation follows the same activate-before-installed invariant as a
    /// hands-on install. Surface publication is the caller's job (launch batches
    /// it because no plugin surface is visible yet).
    func loadAndActivateInstalled() {
        let known = Set(host.lifecyclePluginIDs())
        let stored = Set(defaults.stringArray(forKey: installStateKey) ?? [])
        let target = stored.intersection(known)
        installedIDStrings = []
        for idString in host.lifecyclePluginIDs() where target.contains(idString) {
            activateAndEnterInstalled(idString)
        }
    }

    // MARK: - Lifecycle

    /// Install a plugin: prepare, activate, persist, then register its surfaces
    /// and republish. Takes effect immediately. Idempotent.
    func install(_ idString: String) {
        guard host.lifecyclePluginIDs().contains(idString),
              !installedIDStrings.contains(idString),
              !transitioningIDs.contains(idString) else { return }
        host.prepareLifecycleInstall(idString: idString)
        activateAndEnterInstalled(idString)
        persistInstalledIDs()
        host.registerLifecycleSurfaces(idString: idString)
        publishSurfaces()
        logger.info("Installed plugin \(idString)")
    }

    /// Uninstall a plugin, transactionally: `deactivate` must succeed before any
    /// state or surface changes; a thrown error leaves the plugin fully
    /// installed and rethrows. Idempotent; a concurrent transition is reported.
    func uninstall(_ idString: String) async throws {
        guard host.lifecyclePluginIDs().contains(idString),
              installedIDStrings.contains(idString) else { return }
        guard !transitioningIDs.contains(idString) else {
            throw host.lifecycleTransitionInProgressError(idString: idString)
        }
        transitioningIDs.insert(idString)
        defer { transitioningIDs.remove(idString) }

        try await host.deactivateLifecyclePlugin(idString: idString)

        installedIDStrings.remove(idString)
        persistInstalledIDs()
        host.unregisterLifecycleSurfaces(idString: idString)
        publishSurfaces()
        logger.info("Uninstalled plugin \(idString)")
    }

    /// Adopt the imported install state through the real lifecycle: remove
    /// dropped plugins before installing added ones, run `install`/`uninstall`
    /// for each delta (so activation and surface publication happen exactly like
    /// a hands-on change), re-persist the state that actually converged, and
    /// forward the import to the plugins that end up installed. Returns every
    /// failed or overlapping transition for the kind layer to surface; the
    /// core itself never throws.
    func reconcileAfterImport() async -> [PluginLifecycleReconcileFailure] {
        let known = Set(host.lifecyclePluginIDs())
        let importedIDs = Set(defaults.stringArray(forKey: installStateKey) ?? [])
            .intersection(known)

        var failures: [PluginLifecycleReconcileFailure] = []

        // MainActor methods are re-entrant across `await`. An uninstall that
        // started before the import may still reverse the imported target after
        // this method returns, so the import cannot claim convergence for that
        // plugin. Report it and persist the current truth; the caller can retry
        // once the existing transition completes.
        let blockedIDs = transitioningIDs
        for idString in host.lifecyclePluginIDs() where blockedIDs.contains(idString) {
            failures.append(PluginLifecycleReconcileFailure(
                idString: idString,
                error: host.lifecycleTransitionInProgressError(idString: idString)
            ))
        }

        // Remove first so returning plugins resolve retained conflicts against
        // the actual survivors, including any plugin whose deactivate failed.
        let idsToRemove = installedIDStrings.subtracting(importedIDs).subtracting(blockedIDs)
        for idString in host.lifecyclePluginIDs() where idsToRemove.contains(idString) {
            do {
                try await uninstall(idString)
            } catch {
                logger.error("Import-driven uninstall of \(idString) failed: \(error)")
                failures.append(PluginLifecycleReconcileFailure(idString: idString, error: error))
            }
        }
        let idsToInstall = importedIDs.subtracting(installedIDStrings).subtracting(blockedIDs)
        for idString in host.lifecyclePluginIDs() where idsToInstall.contains(idString) {
            install(idString)
        }

        // Another caller may have entered during one of the awaited removals.
        // Re-check before the final synchronous segment so no transition can
        // outlive a successful reconciliation unnoticed.
        let reportedFailureIDs = Set(failures.map(\.idString))
        for idString in host.lifecyclePluginIDs()
        where transitioningIDs.contains(idString)
            && !reportedFailureIDs.contains(idString) {
            failures.append(PluginLifecycleReconcileFailure(
                idString: idString,
                error: host.lifecycleTransitionInProgressError(idString: idString)
            ))
        }
        persistInstalledIDs()

        for idString in host.lifecyclePluginIDs() where installedIDStrings.contains(idString) {
            host.reconcileLifecycleImport(idString: idString)
        }

        return failures
    }

    // MARK: - Internals

    private func activateAndEnterInstalled(_ idString: String) {
        host.activateLifecyclePlugin(idString: idString)
        installedIDStrings.insert(idString)
    }

    private func persistInstalledIDs() {
        defaults.set(installedIDStrings.sorted(), forKey: installStateKey)
    }

    private func publishSurfaces() {
        host.publishLifecycleSurfaces()
        refreshCommandPalette()
    }
}
