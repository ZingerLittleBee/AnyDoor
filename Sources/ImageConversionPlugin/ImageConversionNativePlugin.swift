import PluginInterface
import SwiftData
import SwiftUI

/// The Image Conversion feature as a Native Plugin (ADR-0005 pilot: own
/// window, own SwiftData model, no system side effects). The module touches
/// the host only through `PluginHostServices`; the host reaches the feature
/// only through this type (plus the registered-debt call sites the PRD
/// carves out: clipboard-history context menu and capture save-as).
@MainActor
public final class ImageConversionNativePlugin: NativePlugin {

    /// Stable persisted identity; never change once shipped.
    public static let pluginID = NativePluginID(rawValue: "imageConversion")

    public let id = ImageConversionNativePlugin.pluginID

    public init(host: any PluginHostServices) {
        PluginHost.bootstrap(host)
    }

    public var localizedName: String { L(.pluginName) }

    public var localizedDescription: String { L(.pluginDescription) }

    public var localizedUninstallImpact: String? { L(.pluginUninstallImpact) }

    public let claimedCommands: Set<BuiltinItem> = [.imageConversion]

    public var providers: [any BuiltinProvider] { [ImageConversionProvider()] }

    /// Nonisolated so the host can register the plugin's schema when building
    /// the ModelContainer, before any MainActor plugin instance exists
    /// (ADR-0005: the schema is static regardless of install state).
    public nonisolated static var modelSchemaTypes: [any PersistentModel.Type] {
        [ImageConversionRecord.self]
    }

    public var modelTypes: [any PersistentModel.Type] { Self.modelSchemaTypes }

    public func hasUsageTrace(in context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<ImageConversionRecord>()) > 0
    }

    public func presentWindow(for command: BuiltinItem) {
        guard command == .imageConversion else { return }
        Task { await ImageConversionWindowController.shared.toggle() }
    }

    public func activate() {
        if let container = PluginHost.services?.modelContainer {
            ImageConversionHistoryStore.shared.configure(modelContainer: container)
        }
        // Sweep candidate session directories a previous process left behind:
        // deinit/reset cleanup never runs on process exit or crash.
        Task.detached(priority: .background) {
            CandidateArtifactStore.cleanupStaleSessions()
        }
    }

    /// Uninstall: the only side effect to revert is in-flight work — cancel
    /// an active Conversion Run (awaiting its cancellation) and close the
    /// workspace window. User data (Conversion Records, preferences, hotkeys)
    /// is retained by design. Never throws: there is no revert that can fail.
    public func deactivate() async throws {
        await ImageConversionWindowController.deactivateForUninstall()
    }

    public func reconcileAfterImport() {
        ImageConversionWindowController.reconcilePreferencesAfterImport()
    }
}
