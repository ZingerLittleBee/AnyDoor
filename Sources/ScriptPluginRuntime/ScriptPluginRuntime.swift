import Foundation
import PluginInterface

/// The headless Script Plugin runtime: a self-contained subsystem the registry
/// (ticket 021) consumes through clean seams. A validated package goes in;
/// palette row descriptors, Detail markdown, action results, and capability side
/// effects come out, with real JavaScriptCore underneath (ADR-0008/0009).
///
/// Owns one ``ScriptPluginContext`` per loaded plugin, each on its own serial
/// queue, so a runaway in one plugin cannot stall another. The runtime itself is
/// `@MainActor` (matching where the registry and capability implementations
/// live); invocations suspend the main actor while the plugin queue works.
@MainActor
public final class ScriptPluginRuntime {
    /// Default hard watchdog deadline (ADR-0008). Injectable so tests need not
    /// wait 30 seconds to observe a kill.
    public static let defaultTimeout: TimeInterval = 30

    private let capabilityHost: ScriptCapabilityHost
    private let timeout: TimeInterval
    private let diagnostics: any ScriptPluginDiagnostics
    private var packages: [ScriptPluginID: ScriptPluginPackage] = [:]
    private var contexts: [ScriptPluginID: ScriptPluginContext] = [:]

    public init(
        capabilityHost: ScriptCapabilityHost,
        timeout: TimeInterval = ScriptPluginRuntime.defaultTimeout,
        diagnostics: any ScriptPluginDiagnostics = NullScriptPluginDiagnostics()
    ) {
        self.capabilityHost = capabilityHost
        self.timeout = timeout
        self.diagnostics = diagnostics
    }

    // MARK: - Load / unload

    /// Register a validated package with the runtime. Rejects a second package
    /// under an already-loaded id (``ScriptPluginError/duplicateID``) without
    /// changing any state. The context is created lazily on first invocation.
    public func load(_ package: ScriptPluginPackage) throws {
        guard packages[package.id] == nil else {
            throw ScriptPluginError.duplicateID(package.id)
        }
        packages[package.id] = package
    }

    /// Load directly from a package directory (validates the manifest first).
    @discardableResult
    public func load(fromDirectory directory: URL) throws -> ScriptPluginID {
        let package = try ScriptPluginPackage.load(fromDirectory: directory)
        try load(package)
        return package.id
    }

    /// Unload a plugin and tear down its context. Its private key-value store on
    /// disk is untouched, so a later reload of the same id finds the data.
    public func unload(_ id: ScriptPluginID) {
        contexts.removeValue(forKey: id)?.teardown()
        packages.removeValue(forKey: id)
    }

    public var loadedIDs: [ScriptPluginID] {
        packages.keys.sorted()
    }

    public func isLoaded(_ id: ScriptPluginID) -> Bool {
        packages[id] != nil
    }

    public func manifest(for id: ScriptPluginID) -> ScriptPluginManifest? {
        packages[id]?.manifest
    }

    // MARK: - Invocation surface

    /// Build the plugin's root palette rows for a query (entry point `rows`).
    public func buildRows(pluginID: ScriptPluginID, query: String) async throws -> [PluginRowDescriptor] {
        let result = try await context(for: pluginID).invoke("rows", arguments: [.string(query)])
        return try ScriptRowDecoder.decode(result)
    }

    /// Build a row's markdown Detail (entry point `detail`).
    public func buildDetail(pluginID: ScriptPluginID, rowID: String) async throws -> String {
        let result = try await context(for: pluginID).invoke("detail", arguments: [.string(rowID)])
        guard let markdown = result.stringValue else {
            throw ScriptPluginError.resultDecodingFailed("detail() must return a string")
        }
        return markdown
    }

    /// Run a row action (entry point `action`) and return its decoded result.
    /// When `argument` is present (the row declared `.enterArgument` and the user
    /// submitted text), it is passed as a third argument so the plugin's
    /// `action(rowID, actionID, argument)` receives it.
    @discardableResult
    public func performAction(
        pluginID: ScriptPluginID,
        rowID: String,
        actionID: String,
        argument: String? = nil
    ) async throws -> ScriptValue {
        var arguments: [ScriptValue] = [.string(rowID), .string(actionID)]
        if let argument { arguments.append(.string(argument)) }
        return try await context(for: pluginID).invoke("action", arguments: arguments)
    }

    /// Generic entry-point invocation, for entry points beyond the three the
    /// palette uses today.
    public func invoke(
        pluginID: ScriptPluginID,
        entryPoint: String,
        arguments: [ScriptValue] = []
    ) async throws -> ScriptValue {
        try await context(for: pluginID).invoke(entryPoint, arguments: arguments)
    }

    // MARK: - Internals

    private func context(for id: ScriptPluginID) throws -> ScriptPluginContext {
        if let existing = contexts[id] { return existing }
        guard let package = packages[id] else {
            throw ScriptPluginError.notLoaded(id)
        }
        let store: (any ScriptKeyValueStore)? = package.manifest.capabilities.contains(.store)
            ? FileScriptKeyValueStore(id: id, directory: capabilityHost.storeDirectory)
            : nil
        let context = ScriptPluginContext(
            id: id,
            package: package,
            capabilityHost: capabilityHost,
            store: store,
            timeout: timeout,
            diagnostics: diagnostics
        )
        contexts[id] = context
        return context
    }
}
