import PluginInterface
import SwiftData
import SwiftUI

/// The Image Conversion feature as a Native Plugin (ADR-0005 pilot: own
/// window, own SwiftData model, no system side effects). The module touches
/// the host only through `PluginHostServices`; the host reaches the feature
/// only through this type (plus the one registered-debt call site the PRD's
/// Out of Scope carves out: the clipboard-history context menu).
@MainActor
public final class ImageConversionNativePlugin: NativePlugin {

    /// Stable persisted identity; never change once shipped.
    nonisolated public static let pluginID = NativePluginID(rawValue: "imageConversion")

    public let id = ImageConversionNativePlugin.pluginID
    private let host: any PluginHostServices
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]

    public init(host: any PluginHostServices) {
        self.host = host
        PluginHost.bootstrap(host)
    }

    public var localizedName: String { L(.pluginName) }

    public var localizedDescription: String { L(.pluginDescription) }

    public var localizedUninstallImpact: String? { L(.pluginUninstallImpact) }

    public let claimedCommands: Set<BuiltinItem> = [.imageConversion]

    public var providers: [any BuiltinProvider] { [ImageConversionProvider()] }

    public nonisolated static var modelSchemaTypes: [any PersistentModel.Type] {
        [ImageConversionRecord.self]
    }

    public func hasUsageTrace(in context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<ImageConversionRecord>()) > 0
    }

    public func activate() {
        ImageConversionHistoryStore.shared.configure(modelContainer: host.modelContainer)
        ImageConversionWindowController.activateForInstall()
        // Sweep candidate session directories a previous process left behind:
        // deinit/reset cleanup never runs on process exit or crash.
        let taskID = UUID()
        cleanupTasks[taskID] = Task.detached(priority: .background) {
            CandidateArtifactStore.cleanupStaleSessions()
        }
    }

    /// Uninstall: the only side effect to revert is in-flight work — dismiss
    /// pending file/folder panels, cancel their tasks and any active Conversion
    /// Run, await all of them, then close the workspace window. User data
    /// (Conversion Records, preferences, hotkeys) is retained by design. Never
    /// throws: there is no revert that can fail.
    public func deactivate() async throws {
        await ImageConversionWindowController.deactivateForUninstall()
        let cleanupTasks = Array(cleanupTasks.values)
        for task in cleanupTasks { task.cancel() }
        for task in cleanupTasks { await task.value }
        self.cleanupTasks.removeAll()
    }

    public func reconcileAfterImport() {
        ImageConversionWindowController.reconcilePreferencesAfterImport()
    }
}
