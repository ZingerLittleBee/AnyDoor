import Foundation
import PluginInterface

/// One chunk of a row's markdown Detail. `more` is the plugin's opaque cursor
/// for the next chunk, or nil when the document is complete; `actions` are the
/// document's footer actions (meaningful on full documents, ignored by the
/// palette on appended chunks).
public struct ScriptDetailChunk: Sendable, Equatable {
    public let markdown: String
    public let more: String?
    public let actions: [PluginRowDetailAction]

    public init(markdown: String, more: String?, actions: [PluginRowDetailAction] = []) {
        self.markdown = markdown
        self.more = more
        self.actions = actions
    }
}

/// One page of a `pushList` row's second-level list. `more` is the plugin's
/// opaque cursor for the next page, or nil when the list is complete.
public struct ScriptListChunk: Sendable, Equatable {
    public let rows: [PluginRowDescriptor]
    public let more: String?

    public init(rows: [PluginRowDescriptor], more: String?) {
        self.rows = rows
        self.more = more
    }
}

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

    /// Build a `pushList` row's second-level page (entry point `list`). The list
    /// id and the current second-level query are passed to `list(listId, query)`;
    /// a plugin without a `list` handler surfaces `entryPointMissing`, which the
    /// row source turns into an inline error row.
    ///
    /// A nil `cursor` requests the initial page; a non-nil cursor (the previous
    /// page's `more`, opaque to the host) is passed as `list`'s third argument
    /// to request the next page. The plugin returns either a plain row array (a
    /// complete list, nothing more to load) or `{ rows, more? }` to offer
    /// pagination — mirroring `detail`'s chunked result.
    public func buildList(
        pluginID: ScriptPluginID, listID: String, query: String, cursor: String? = nil
    ) async throws -> ScriptListChunk {
        var arguments: [ScriptValue] = [.string(listID), .string(query)]
        if let cursor { arguments.append(.string(cursor)) }
        let result = try await context(for: pluginID).invoke("list", arguments: arguments)
        if case .object(let fields) = result, let rowsValue = fields["rows"] {
            let more: String?
            switch fields["more"] {
            case .none, .some(.null):
                more = nil
            case .some(let value):
                guard let cursor = value.stringValue else {
                    throw ScriptPluginError.resultDecodingFailed("list() 'more' must be a string")
                }
                more = cursor
            }
            return ScriptListChunk(rows: try ScriptRowDecoder.decode(rowsValue), more: more)
        }
        return ScriptListChunk(rows: try ScriptRowDecoder.decode(result), more: nil)
    }

    /// Build a row's markdown Detail chunk (entry point `detail`).
    ///
    /// A nil `cursor` requests the initial document; a non-nil cursor (the
    /// previous chunk's `more`, opaque to the host) is passed as `detail`'s
    /// second argument to request the next chunk. The plugin returns either a
    /// plain markdown string (a complete document, nothing more to load) or
    /// `{ markdown, more? }` to offer pagination.
    public func buildDetail(
        pluginID: ScriptPluginID, rowID: String, cursor: String? = nil
    ) async throws -> ScriptDetailChunk {
        var arguments: [ScriptValue] = [.string(rowID)]
        if let cursor { arguments.append(.string(cursor)) }
        let result = try await context(for: pluginID).invoke("detail", arguments: arguments)
        return try Self.decodeDetailChunk(result, entryPoint: "detail")
    }

    /// Run a Detail footer action (entry point `detailAction`) and build the
    /// replacement document. A plugin whose Detail declared actions but has no
    /// `detailAction` handler surfaces `entryPointMissing` — a visible failure,
    /// not a silent no-op.
    public func buildDetailAction(
        pluginID: ScriptPluginID, rowID: String, actionID: String
    ) async throws -> ScriptDetailChunk {
        let result = try await context(for: pluginID)
            .invoke("detailAction", arguments: [.string(rowID), .string(actionID)])
        return try Self.decodeDetailChunk(result, entryPoint: "detailAction")
    }

    /// Decode a detail-shaped result: a plain markdown string (complete
    /// document, no cursor, no actions) or `{ markdown, more?, actions? }`.
    private static func decodeDetailChunk(
        _ result: ScriptValue, entryPoint: String
    ) throws -> ScriptDetailChunk {
        if let markdown = result.stringValue {
            return ScriptDetailChunk(markdown: markdown, more: nil)
        }
        guard case .object(let fields) = result, let markdown = fields["markdown"]?.stringValue else {
            throw ScriptPluginError.resultDecodingFailed(
                "\(entryPoint)() must return a string or { markdown, more?, actions? }")
        }

        let more: String?
        switch fields["more"] {
        case .none, .some(.null):
            more = nil
        case .some(let value):
            guard let cursor = value.stringValue else {
                throw ScriptPluginError.resultDecodingFailed("\(entryPoint)() 'more' must be a string")
            }
            more = cursor
        }

        var actions: [PluginRowDetailAction] = []
        switch fields["actions"] {
        case .none, .some(.null):
            break
        case .some(.array(let items)):
            actions = try items.map { item in
                guard case .object(let action) = item,
                      let id = action["id"]?.stringValue, !id.isEmpty,
                      let label = action["label"]?.stringValue, !label.isEmpty else {
                    throw ScriptPluginError.resultDecodingFailed(
                        "\(entryPoint)() 'actions' entries must be { id, label } with non-empty strings")
                }
                return PluginRowDetailAction(id: id, label: label)
            }
        case .some:
            throw ScriptPluginError.resultDecodingFailed("\(entryPoint)() 'actions' must be an array")
        }

        return ScriptDetailChunk(markdown: markdown, more: more, actions: actions)
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
