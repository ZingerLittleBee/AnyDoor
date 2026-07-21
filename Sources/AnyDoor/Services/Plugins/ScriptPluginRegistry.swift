import AppKit
import Foundation
import Observation
import PluginInterface
import ScriptPluginRuntime

/// A concurrent Script Plugin transition already in flight for the same id.
/// The Script-kind analogue of `PluginTransitionInProgressError`.
struct ScriptPluginTransitionInProgressError: LocalizedError, Equatable, Sendable {
    let pluginID: ScriptPluginID
    let message: String

    var errorDescription: String? { message }
}

/// The Script-Plugin kind of the shared plugin lifecycle (ADR-0005/0008).
///
/// Script Plugins join the registry machinery as the **second kind** by driving
/// the same kind-agnostic `PluginLifecycleCore` that `PluginRegistry` drives for
/// Native Plugins — a distinct core instance with its own install-state key, not
/// a parallel reimplementation. Where a Native Plugin's code always ships in the
/// binary and "install" flips a flag, a Script Plugin is Sideloaded from disk:
/// installing copies the package into the app's storage and marks it installed;
/// uninstalling removes that copy and every surface while the plugin's private
/// key-value store is retained, so reinstalling the same id finds its data.
///
/// Script Plugins contribute exactly one surface — a command-palette root row
/// source — so the kind-specific publish hook is empty and the shared palette
/// recomposition (owned by the core) does all the work. Install state and the
/// private store are deliberately machine-local: the install-state key is absent
/// from `SyncSettingsRegistry`, so it never enters a config backup.
@MainActor
@Observable
final class ScriptPluginRegistry {
    /// UserDefaults key holding the installed Script Plugin id strings.
    /// **Not** whitelisted in `SyncSettingsRegistry` — Script Plugin packages
    /// live only on the local machine, so their install state must never travel
    /// in a config backup (user story 17).
    nonisolated static let installStateKey = "plugins.script.installed"

    /// The production registry, wired to Core services. Its runtime, capability
    /// host, and storage directories are built lazily on first access, on the
    /// main actor. `AppDelegate` bootstraps it at launch.
    static let shared = ScriptPluginRegistry.makeShared()

    private static func makeShared() -> ScriptPluginRegistry {
        let base = scriptPluginSupportDirectory()
        let host = ScriptCapabilityHost(
            transport: URLSessionFetchTransport(),
            storeDirectory: base.appendingPathComponent("stores", isDirectory: true),
            presentToast: { _, toast in
                switch toast {
                case .success(let message): ToastPresenter.shared.show(.success(message))
                case .info(let message): ToastPresenter.shared.show(.info(message))
                case .failure(let message): ToastPresenter.shared.show(.failure(message))
                }
            },
            writePasteboard: { text in ClipboardWatcher.selfWrite(string: text) },
            openURL: { url in NSWorkspace.shared.open(url) }
        )
        return ScriptPluginRegistry(
            runtime: ScriptPluginRuntime(capabilityHost: host),
            packagesDirectory: base.appendingPathComponent("packages", isDirectory: true)
        )
    }

    /// `~/Library/Application Support/dev.bybee.AnyDoor/ScriptPlugins`, the root
    /// for installed package copies and their private stores. Shares the pinned
    /// support directory the ModelContainer uses, so `swift run` and the `.app`
    /// see the same plugins.
    private static func scriptPluginSupportDirectory() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("dev.bybee.AnyDoor", isDirectory: true)
            .appendingPathComponent("ScriptPlugins", isDirectory: true)
    }

    /// Owner-id prefix that namespaces a Script Plugin's palette row source into
    /// the shared `PluginRowSourceKey` space. Native Plugin ids never contain a
    /// colon, so a Script Plugin id can never collide with a Native one even if
    /// their raw strings match (user story 24).
    private static let rowSourceOwnerPrefix = "script:"

    /// Packages known to this registry: discovered on disk at bootstrap and
    /// added on Sideload. Keyed by manifest id.
    @ObservationIgnored private var knownPackages: [ScriptPluginID: ScriptPluginPackage] = [:]
    /// The live palette row source per installed plugin, kept so its
    /// registration can be reverted on uninstall.
    @ObservationIgnored private var rowSources: [ScriptPluginID: ScriptPluginRowSource] = [:]

    @ObservationIgnored private let runtime: ScriptPluginRuntime
    @ObservationIgnored private let packagesDirectory: URL
    @ObservationIgnored private let paletteExtensions: CommandPaletteExtensions
    @ObservationIgnored private let languageCode: @MainActor () -> String?
    @ObservationIgnored private var isBootstrapped = false
    /// The shared, kind-agnostic lifecycle engine — a Script-kind instance,
    /// distinct from `PluginRegistry`'s Native-kind instance.
    @ObservationIgnored private var core: PluginLifecycleCore!

    init(
        runtime: ScriptPluginRuntime,
        packagesDirectory: URL,
        paletteExtensions: CommandPaletteExtensions = .shared,
        defaults: UserDefaults = .standard,
        languageCode: @escaping @MainActor () -> String? = {
            LocalizationManager.shared.effectiveLocale.language.languageCode?.identifier
        },
        refreshCommandPalette: @escaping @MainActor () -> Void = {
            CommandPaletteWindowController.shared.refreshPluginSurfaces()
        }
    ) {
        self.runtime = runtime
        self.packagesDirectory = packagesDirectory
        self.paletteExtensions = paletteExtensions
        self.languageCode = languageCode
        self.core = PluginLifecycleCore(
            host: self,
            installStateKey: Self.installStateKey,
            defaults: defaults,
            refreshCommandPalette: refreshCommandPalette
        )
    }

    // MARK: - Bootstrap

    /// Discover packages already in storage, activate every persisted-installed
    /// one, and register its palette surface. No palette recomposition here:
    /// like the Native bootstrap, launch has no visible palette to refresh.
    func bootstrap() {
        precondition(!isBootstrapped, "ScriptPluginRegistry.bootstrap may only run once")
        isBootstrapped = true
        discoverPackagesOnDisk()
        core.loadAndActivateInstalled()
        for idString in core.installedIDStrings where knownPackages[ScriptPluginID(idString)] != nil {
            registerLifecycleSurfaces(idString: idString)
        }
    }

    /// Scan the packages directory and load every valid manifest into the known
    /// set. A directory with a corrupt or missing manifest is skipped — it can
    /// never be activated, so it is simply invisible.
    private func discoverPackagesOnDisk() {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: packagesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for directory in entries {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let package = try? ScriptPluginPackage.load(fromDirectory: directory) else { continue }
            knownPackages[package.id] = package
        }
    }

    // MARK: - Queries (Settings surface)

    /// The installed Script Plugins' manifests, sorted by id, for the Plugins
    /// settings list. Reading `core.installedIDStrings` registers Observation so
    /// the list updates on install/uninstall without a relaunch.
    var installedManifests: [ScriptPluginManifest] {
        core.installedIDStrings
            .compactMap { knownPackages[ScriptPluginID($0)]?.manifest }
            .sorted { $0.id < $1.id }
    }

    func isInstalled(_ id: ScriptPluginID) -> Bool {
        core.contains(id.rawValue)
    }

    /// The row source for an installed plugin (test seam: await its `refresh()`
    /// to observe rows deterministically).
    func rowSource(for id: ScriptPluginID) -> ScriptPluginRowSource? {
        rowSources[id]
    }

    // MARK: - Sideload / uninstall

    /// Sideload a package from a folder the user picked: validate, refuse a
    /// duplicate id, copy into storage, and install through the lifecycle. Every
    /// refusal is raised **before** any copy, so an invalid or duplicate package
    /// changes nothing on disk, in the registry, or in Settings (user story 3).
    @discardableResult
    func sideload(fromDirectory source: URL) throws -> ScriptPluginID {
        // Validates the manifest; throws a typed `ScriptManifestError` and reads
        // no bundle, so a malformed package is refused without side effects.
        let package = try ScriptPluginPackage.load(fromDirectory: source)
        let id = package.id

        guard knownPackages[id] == nil, !core.contains(id.rawValue) else {
            throw ScriptPluginError.duplicateID(id)
        }

        let destination = packageDirectory(for: id)
        do {
            try FileManager.default.createDirectory(
                at: packagesDirectory, withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            // Re-anchor the package at its installed location so the runtime and
            // future launches read the copy, not the user's original folder.
            let installed = try ScriptPluginPackage.load(fromDirectory: destination)
            knownPackages[id] = installed
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        core.install(id.rawValue)
        return id
    }

    /// Uninstall a Script Plugin: tear down its context, remove the package copy
    /// and every surface, and retain its private key-value store so a reinstall
    /// of the same id restores prior data. Idempotent; a concurrent transition
    /// is reported.
    func uninstall(_ id: ScriptPluginID) async throws {
        try await core.uninstall(id.rawValue)
    }

    // MARK: - Internals

    private func packageDirectory(for id: ScriptPluginID) -> URL {
        // Percent-encode the id so an author-namespaced id ("author.plugin")
        // maps to a safe single directory name — same scheme the private store
        // uses for its file, so the two stay parallel.
        let encoded = id.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? id.rawValue
        return packagesDirectory.appendingPathComponent(encoded, isDirectory: true)
    }

    private func rowSourceOwnerID(for id: ScriptPluginID) -> NativePluginID {
        NativePluginID(rawValue: Self.rowSourceOwnerPrefix + id.rawValue)
    }

    private func rowSourceKey(for id: ScriptPluginID) -> PluginRowSourceKey {
        PluginRowSourceKey(pluginID: rowSourceOwnerID(for: id), localID: ScriptPluginRowSource.localID)
    }
}

// MARK: - Localized refusal messages

/// Maps a Sideload refusal to a clear, localized message for the Settings toast.
/// Every case is a typed refusal from the runtime's manifest/loader boundary, so
/// a bad package always explains itself rather than surfacing a raw error string.
@MainActor
func scriptSideloadFailureMessage(_ error: any Error) -> String {
    switch error {
    case let manifest as ScriptManifestError:
        switch manifest {
        case .missingField(let field): return L(.pluginsSideloadErrorMissingField, field)
        case .invalidJSON: return L(.pluginsSideloadErrorInvalidJSON)
        case .fileUnreadable: return L(.pluginsSideloadErrorFileUnreadable)
        case .unknownAPIVersion(let version): return L(.pluginsSideloadErrorUnknownAPIVersion, version)
        case .unknownCapability(let key): return L(.pluginsSideloadErrorUnknownCapability, key)
        }
    case ScriptPluginError.duplicateID:
        return L(.pluginsSideloadErrorDuplicate)
    default:
        return error.localizedDescription
    }
}

// MARK: - AnyPluginLifecycleHost (the Script-kind driver of the shared core)

/// The Script-Plugin implementation of the kind-agnostic lifecycle hooks. The
/// core speaks opaque id strings; each method resolves the string back to a
/// `ScriptPluginID` and applies the Script-specific behavior — loading the
/// package into the runtime, registering the palette row source, tearing the
/// context down, and removing the on-disk copy.
extension ScriptPluginRegistry: AnyPluginLifecycleHost {
    func lifecyclePluginIDs() -> [String] {
        knownPackages.keys.map(\.rawValue).sorted()
    }

    func activateLifecyclePlugin(idString: String) {
        let id = ScriptPluginID(idString)
        guard let package = knownPackages[id] else { return }
        // Idempotent: a fresh package loads; a reload of an already-loaded id is
        // refused by the runtime and is not an error here.
        try? runtime.load(package)
    }

    func deactivateLifecyclePlugin(idString: String) async throws {
        // Script deactivation only tears down the JS context; it has no external
        // side effects, so (unlike a Native Plugin) it never throws to abort.
        runtime.unload(ScriptPluginID(idString))
    }

    func prepareLifecycleInstall(idString: String) {
        // Script Plugins claim no closed commands and record no hotkeys, so there
        // is no retained-hotkey conflict to resolve before install.
    }

    func registerLifecycleSurfaces(idString: String) {
        let id = ScriptPluginID(idString)
        guard let package = knownPackages[id] else { return }
        let source = ScriptPluginRowSource(
            scriptID: id,
            runtime: runtime,
            sectionTitle: package.manifest.displayName(forLanguageCode: languageCode())
        )
        rowSources[id] = source
        paletteExtensions.registerRowSource(source, ownerID: rowSourceOwnerID(for: id))
        // Kick the initial async fetch so rows are ready by the time the user
        // types into the palette.
        source.reload()
    }

    func unregisterLifecycleSurfaces(idString: String) {
        let id = ScriptPluginID(idString)
        rowSources.removeValue(forKey: id)
        paletteExtensions.unregisterRowSource(key: rowSourceKey(for: id))
        // Remove the installed package copy; the private key-value store lives in
        // a separate directory and is intentionally left in place.
        knownPackages.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: packageDirectory(for: id))
    }

    func publishLifecycleSurfaces() {
        // Script Plugins contribute no panel rows or hotkeys; the only surface is
        // the palette row source, and the core recomposes a visible palette
        // through `refreshCommandPalette`. Nothing kind-specific to publish.
    }

    func reconcileLifecycleImport(idString: String) {
        // Script Plugin install state is excluded from config backup, so import
        // reconciliation never reaches this kind.
    }

    func lifecycleTransitionInProgressError(idString: String) -> any Error {
        ScriptPluginTransitionInProgressError(
            pluginID: ScriptPluginID(idString),
            message: L(.pluginsTransitionInProgress)
        )
    }
}
