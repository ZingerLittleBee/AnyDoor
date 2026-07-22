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

    /// UserDefaults key for the machine-local developer-mode switch. With it off
    /// no Dev Plugin affordance exists anywhere in Settings (ticket 023).
    /// Deliberately **not** in `SyncSettingsRegistry`: developer mode is a
    /// per-machine authoring convenience, never carried in a config backup.
    nonisolated static let developerModeKey = "plugins.script.developerMode"

    /// UserDefaults key holding the registered Dev Plugin directory paths. Also
    /// machine-local and out of the sync whitelist — a dev directory only exists
    /// on the author's machine.
    nonisolated static let devDirectoriesKey = "plugins.script.devDirectories"

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
            openURL: { url in NSWorkspace.shared.open(url) },
            translate: { text in try await PluginTranslator.translate(text) }
        )
        // One diagnostics log shared by the runtime (context-level refusals,
        // watchdog kills, capability errors) and the registry (dev-plugin reload
        // refusals), so every Script Plugin's failures land in its own log file.
        let diagnostics = FileScriptPluginLog(
            directory: base.appendingPathComponent("logs", isDirectory: true)
        )
        return ScriptPluginRegistry(
            runtime: ScriptPluginRuntime(capabilityHost: host, diagnostics: diagnostics),
            packagesDirectory: base.appendingPathComponent("packages", isDirectory: true),
            diagnostics: diagnostics
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
    /// The live palette row source per active plugin (installed **or** dev),
    /// kept so its registration can be reverted on uninstall or removal.
    @ObservationIgnored private var rowSources: [ScriptPluginID: ScriptPluginRowSource] = [:]

    /// Registered Dev Plugin directories, keyed by manifest id. Durable across a
    /// developer-mode toggle (persisted to `devDirectoriesKey`); the value is the
    /// author's development directory, loaded **in place** and never copied.
    @ObservationIgnored private var devDirectories: [ScriptPluginID: URL] = [:]
    /// The active runtime state per Dev Plugin — present only while developer
    /// mode is on. Disabling developer mode tears these down but keeps
    /// `devDirectories`, so re-enabling restores them.
    @ObservationIgnored private var activeDevPlugins: [ScriptPluginID: DevPluginState] = [:]
    /// Developer-mode switch, seeded from defaults; observed so the Settings
    /// toggle reflects it. Mutated only through `setDeveloperMode`.
    private var developerModeEnabled: Bool
    /// Bumped whenever `activeDevPlugins` changes so the observed
    /// `devPluginManifests` list refreshes the Settings UI (the map itself is
    /// `@ObservationIgnored` because it holds live objects).
    private var activeDevPluginsObservationToken = 0

    @ObservationIgnored private let runtime: ScriptPluginRuntime
    @ObservationIgnored private let packagesDirectory: URL
    @ObservationIgnored private let diagnostics: any ScriptPluginDiagnostics
    @ObservationIgnored private let paletteExtensions: CommandPaletteExtensions
    @ObservationIgnored private let languageCode: @MainActor () -> String?
    /// Presents a Dev Plugin's action failure with full detail (the author wants
    /// the message and stack, not the generic toast a normal user sees).
    @ObservationIgnored private let presentDevActionFailure: @MainActor (ScriptPluginID, ScriptPluginError) -> Void
    /// Nudges a visible palette to recompute its rows when an async row source
    /// finishes loading, without discarding a drilled-in Detail (unlike the full
    /// `refreshCommandPalette` recomposition used on install/uninstall).
    @ObservationIgnored private let notifyRowsChanged: @MainActor () -> Void
    /// Presents the failure toast when a committed Script Plugin row action
    /// throws (user story 16). Injectable so tests observe it without a window.
    @ObservationIgnored private let presentActionFailure: @MainActor (ScriptPluginID) -> Void
    @ObservationIgnored private var isBootstrapped = false
    /// The shared, kind-agnostic lifecycle engine — a Script-kind instance,
    /// distinct from `PluginRegistry`'s Native-kind instance.
    @ObservationIgnored private var core: PluginLifecycleCore!

    init(
        runtime: ScriptPluginRuntime,
        packagesDirectory: URL,
        diagnostics: any ScriptPluginDiagnostics = NullScriptPluginDiagnostics(),
        paletteExtensions: CommandPaletteExtensions = .shared,
        defaults: UserDefaults = .standard,
        languageCode: @escaping @MainActor () -> String? = {
            LocalizationManager.shared.effectiveLocale.language.languageCode?.identifier
        },
        refreshCommandPalette: @escaping @MainActor () -> Void = {
            CommandPaletteWindowController.shared.refreshPluginSurfaces()
        },
        notifyRowsChanged: @escaping @MainActor () -> Void = {
            CommandPaletteWindowController.shared.refreshVisibleRows()
        },
        presentActionFailure: @escaping @MainActor (ScriptPluginID) -> Void = { _ in
            ToastPresenter.shared.show(.failure(L(.pluginsActionFailed)))
        },
        presentDevActionFailure: @escaping @MainActor (ScriptPluginID, ScriptPluginError) -> Void = { _, error in
            ToastPresenter.shared.show(.failure(ScriptPluginErrorPresentation.detail(of: error)))
        }
    ) {
        self.runtime = runtime
        self.packagesDirectory = packagesDirectory
        self.diagnostics = diagnostics
        self.paletteExtensions = paletteExtensions
        self.languageCode = languageCode
        self.notifyRowsChanged = notifyRowsChanged
        self.presentActionFailure = presentActionFailure
        self.presentDevActionFailure = presentDevActionFailure
        self.developerModeEnabled = defaults.bool(forKey: Self.developerModeKey)
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
        loadPersistedDevDirectories()
        // Dev Plugins load in place only behind the developer-mode switch; with
        // it off they stay dormant on disk and contribute nothing.
        if developerModeEnabled {
            for (_, directory) in devDirectories.sorted(by: { $0.key < $1.key }) {
                activateDevPlugin(directory: directory)
            }
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

        guard !isIDInUse(id) else {
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

    // MARK: - Developer mode

    /// The machine-local developer-mode switch. With it off the Settings UI hides
    /// every Dev Plugin affordance; reading it here registers Observation so the
    /// toggle stays in sync.
    var isDeveloperModeEnabled: Bool {
        developerModeEnabled
    }

    /// Flip developer mode. Turning it **on** activates every persisted Dev
    /// Plugin (in place, with its watcher); turning it **off** tears their
    /// surfaces and contexts down while keeping the persisted directory list, so
    /// re-enabling restores them. The development directories are never touched.
    func setDeveloperMode(_ enabled: Bool) {
        guard enabled != developerModeEnabled else { return }
        developerModeEnabled = enabled
        core.defaults.set(enabled, forKey: Self.developerModeKey)
        if enabled {
            for (_, directory) in devDirectories.sorted(by: { $0.key < $1.key }) {
                activateDevPlugin(directory: directory)
            }
        } else {
            for id in Array(activeDevPlugins.keys) {
                deactivateDevPlugin(id)
            }
        }
        core.publishSurfaces()
    }

    // MARK: - Dev Plugin registration (in place, never copied)

    /// The manifests of the currently active Dev Plugins, sorted by id, for the
    /// Settings list. Empty when developer mode is off.
    var devPluginManifests: [ScriptPluginManifest] {
        _ = activeDevPluginsObservationToken
        return activeDevPlugins.values
            .compactMap { runtime.manifest(for: $0.id) }
            .sorted { $0.id < $1.id }
    }

    /// The development directory a Dev Plugin is loaded from, for the Settings row.
    func devPluginDirectory(for id: ScriptPluginID) -> URL? {
        devDirectories[id]
    }

    /// Register an author's development directory as a Dev Plugin, loaded **in
    /// place** — the package is validated and handed to the runtime straight from
    /// the development directory, never copied into app storage (ticket 023). The
    /// host never modifies that directory. Refuses a duplicate id (an installed or
    /// already-registered plugin) so the shared runtime id space stays exclusive.
    @discardableResult
    func registerDevPlugin(fromDirectory directory: URL) throws -> ScriptPluginID {
        guard developerModeEnabled else { throw ScriptDevPluginError.developerModeDisabled }
        let standardized = directory.standardizedFileURL
        // Validate the manifest in place; throws a typed error and reads no
        // bundle, so a malformed dev package is refused without side effects.
        let package = try ScriptPluginPackage.load(fromDirectory: standardized)
        let id = package.id
        guard !isIDInUse(id) else { throw ScriptPluginError.duplicateID(id) }

        devDirectories[id] = standardized
        persistDevDirectories()
        activateDevPlugin(directory: standardized)
        core.publishSurfaces()
        return id
    }

    /// Remove a Dev Plugin registration: tear down its surfaces and context and
    /// drop the persisted directory. The development directory itself is never
    /// modified — only the host-side registration and the JS context are removed.
    func unregisterDevPlugin(_ id: ScriptPluginID) {
        guard devDirectories[id] != nil else { return }
        deactivateDevPlugin(id)
        devDirectories.removeValue(forKey: id)
        persistDevDirectories()
        core.publishSurfaces()
    }

    /// Whether a plugin id is a registered Dev Plugin (installed-in-place).
    func isDevPlugin(_ id: ScriptPluginID) -> Bool {
        devDirectories[id] != nil
    }

    /// Reload a Dev Plugin's context from its development directory. The runtime
    /// re-reads the manifest and bundle, so an edit to the bundle takes effect at
    /// the next invocation and already-visible palette rows refresh. A manifest
    /// that no longer validates (or whose id changed) is a load refusal: it is
    /// logged and surfaced to the author through the row source's failed state.
    func reloadDevPlugin(_ id: ScriptPluginID) {
        guard let directory = devDirectories[id], let state = activeDevPlugins[id] else { return }
        do {
            let reloaded = try ScriptPluginPackage.load(fromDirectory: directory)
            guard reloaded.id == id else {
                throw ScriptPluginError.bundleEvaluationFailed(
                    "plugin id changed on reload: expected \(id.rawValue), got \(reloaded.id.rawValue)")
            }
            runtime.unload(id)
            try runtime.load(reloaded)
            state.source.reload()
        } catch {
            runtime.unload(id)
            diagnostics.record(ScriptDiagnosticEvent(
                pluginID: id, category: .loadRefused,
                message: "dev reload refused: \(ScriptPluginErrorPresentation.detail(of: error))"))
            state.source.reportLoadFailure(ScriptPluginErrorPresentation.detail(of: error))
        }
        notifyRowsChanged()
    }

    // MARK: - Dev Plugin internals

    /// Activate a Dev Plugin from its development directory: load it into the
    /// shared runtime in place and register its palette row source (which surfaces
    /// error detail to the author). Idempotent for a directory whose id is already
    /// active. Never copies and never writes to `directory`.
    private func activateDevPlugin(directory: URL) {
        guard let package = try? ScriptPluginPackage.load(fromDirectory: directory) else {
            // A persisted directory whose manifest no longer validates: skip
            // activation but keep the registration so the author can fix it.
            return
        }
        let id = package.id
        guard activeDevPlugins[id] == nil, !runtime.isLoaded(id) else { return }
        do {
            try runtime.load(package)
        } catch {
            return
        }
        let source = registerRowSource(for: package, surfacesErrorDetail: true)
        let watcher = makeDevWatcher(for: id, directory: directory)
        activeDevPlugins[id] = DevPluginState(id: id, source: source, watcher: watcher)
        activeDevPluginsObservationToken &+= 1
    }

    /// Tear down a Dev Plugin's active runtime state without touching its
    /// registration or its development directory.
    private func deactivateDevPlugin(_ id: ScriptPluginID) {
        guard let state = activeDevPlugins.removeValue(forKey: id) else { return }
        activeDevPluginsObservationToken &+= 1
        state.watcher?.cancel()
        unregisterRowSource(for: id)
        runtime.unload(id)
    }

    // MARK: - Row-source surface (shared by installed and Dev Plugins)

    /// Build, index, and register the palette row source for a loaded plugin,
    /// then kick its initial async fetch — the one implementation of bringing a
    /// Script Plugin's palette surface up, used by the installed lifecycle hook
    /// and the Dev Plugin path alike. Dev Plugins surface full error detail to
    /// the author; installed plugins show the generic failure toast.
    @discardableResult
    private func registerRowSource(
        for package: ScriptPluginPackage, surfacesErrorDetail: Bool
    ) -> ScriptPluginRowSource {
        let id = package.id
        let onActionError: @MainActor @Sendable (ScriptPluginError) -> Void
        if surfacesErrorDetail {
            onActionError = { [presentDevActionFailure] error in presentDevActionFailure(id, error) }
        } else {
            onActionError = { [presentActionFailure] _ in presentActionFailure(id) }
        }
        let source = ScriptPluginRowSource(
            scriptID: id,
            runtime: runtime,
            sectionTitle: package.manifest.displayName(forLanguageCode: languageCode()),
            surfacesErrorDetail: surfacesErrorDetail,
            onRowsChanged: notifyRowsChanged,
            onActionError: onActionError
        )
        rowSources[id] = source
        paletteExtensions.registerRowSource(source, ownerID: rowSourceOwnerID(for: id))
        // Kick the initial async fetch so rows are ready by the time the user
        // types into the palette.
        source.reload()
        return source
    }

    /// Drop a plugin's row source and revert its palette registration — the one
    /// implementation of tearing a Script Plugin's palette surface down.
    private func unregisterRowSource(for id: ScriptPluginID) {
        rowSources.removeValue(forKey: id)
        paletteExtensions.unregisterRowSource(key: rowSourceKey(for: id))
    }

    /// Overridden by ticket 023's watcher slice; nil keeps activation working
    /// before the watcher exists.
    private func makeDevWatcher(for id: ScriptPluginID, directory: URL) -> DirectoryWatcher? {
        DirectoryWatcher(directory: directory) { [weak self] in
            self?.reloadDevPlugin(id)
        }
    }

    private func loadPersistedDevDirectories() {
        let paths = core.defaults.stringArray(forKey: Self.devDirectoriesKey) ?? []
        for path in paths {
            let directory = URL(fileURLWithPath: path).standardizedFileURL
            guard let package = try? ScriptPluginPackage.load(fromDirectory: directory) else { continue }
            devDirectories[package.id] = directory
        }
    }

    private func persistDevDirectories() {
        core.defaults.set(devDirectories.values.map(\.path).sorted(), forKey: Self.devDirectoriesKey)
    }

    /// Whether an id is already claimed by an installed package or a Dev Plugin —
    /// they share the runtime's single id space, so it must be exclusive.
    private func isIDInUse(_ id: ScriptPluginID) -> Bool {
        knownPackages[id] != nil || core.contains(id.rawValue) || devDirectories[id] != nil
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

// MARK: - Dev Plugin support types

/// The active runtime state for one registered Dev Plugin: its palette row
/// source and the file-system watcher that reloads it on a change. Held only
/// while developer mode is on.
@MainActor
private final class DevPluginState {
    let id: ScriptPluginID
    let source: ScriptPluginRowSource
    let watcher: DirectoryWatcher?

    init(id: ScriptPluginID, source: ScriptPluginRowSource, watcher: DirectoryWatcher?) {
        self.id = id
        self.source = source
        self.watcher = watcher
    }
}

/// A refusal specific to Dev Plugin registration.
enum ScriptDevPluginError: LocalizedError, Equatable {
    /// Registration was attempted while developer mode is off (defensive — the
    /// UI gates the affordance behind the switch).
    case developerModeDisabled

    var errorDescription: String? {
        switch self {
        case .developerModeDisabled: return "Developer mode is disabled."
        }
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

    // `prepareLifecycleInstall`, `publishLifecycleSurfaces`, and
    // `reconcileLifecycleImport` use the protocol's default no-ops: Script
    // Plugins claim no closed commands, record no hotkeys, have no
    // kind-specific surface beyond the core-owned palette, and keep their
    // install state out of config backup.

    func registerLifecycleSurfaces(idString: String) {
        let id = ScriptPluginID(idString)
        guard let package = knownPackages[id] else { return }
        registerRowSource(for: package, surfacesErrorDetail: false)
    }

    func unregisterLifecycleSurfaces(idString: String) {
        let id = ScriptPluginID(idString)
        unregisterRowSource(for: id)
        // Remove the installed package copy; the private key-value store lives in
        // a separate directory and is intentionally left in place.
        knownPackages.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: packageDirectory(for: id))
    }

    func lifecycleTransitionInProgressError(idString: String) -> any Error {
        ScriptPluginTransitionInProgressError(
            pluginID: ScriptPluginID(idString),
            message: L(.pluginsTransitionInProgress)
        )
    }
}
