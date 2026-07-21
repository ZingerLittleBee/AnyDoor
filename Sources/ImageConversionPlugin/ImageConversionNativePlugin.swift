import PluginInterface
import SwiftData
import SwiftUI

/// The Image Conversion feature as a Native Plugin (ADR-0005 pilot: own
/// window, own SwiftData model, no system side effects). The module touches
/// the host only through `PluginHostServices`; the host reaches the feature
/// only through this type. The clipboard-history "Convert Image Format"
/// entry is a generic `PluginClipboardAction` contribution — the host
/// surfaces and routes it without naming this plugin.
@MainActor
public final class ImageConversionNativePlugin: NativePlugin {

    /// Stable persisted identity; never change once shipped.
    nonisolated public static let pluginID = NativePluginID(rawValue: "imageConversion")

    public let id = ImageConversionNativePlugin.pluginID
    private let hostContext: PluginHostContext
    let historyStore: ImageConversionHistoryStore
    private var windowControllerStorage: ImageConversionWindowController?
    private var isActive = false
    private lazy var provider = ImageConversionProvider { [weak self] in
        await self?.toggleWindow()
    }
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]

    var windowController: ImageConversionWindowController {
        if let windowControllerStorage { return windowControllerStorage }
        let controller = ImageConversionWindowController(
            hostContext: hostContext,
            historyStore: historyStore
        )
        if isActive { controller.activateForInstall() }
        windowControllerStorage = controller
        return controller
    }

    var hasCreatedWindowController: Bool {
        windowControllerStorage != nil
    }

    public init(host: any PluginHostServices) {
        let hostContext = PluginHostContext(services: host)
        self.hostContext = hostContext
        self.historyStore = ImageConversionHistoryStore(
            modelContext: host.modelContainer.mainContext
        )
    }

    public var localizedName: String { L(hostContext, .pluginName) }

    public var localizedDescription: String { L(hostContext, .pluginDescription) }

    public var localizedUninstallImpact: String? { L(hostContext, .pluginUninstallImpact) }

    public let claimedCommands: Set<BuiltinItem> = [.imageConversion]

    public var providers: [any BuiltinProvider] { [provider] }

    public nonisolated static var modelSchemaTypes: [any PersistentModel.Type] {
        [ImageConversionRecord.self]
    }

    public func hasUsageTrace(in context: ModelContext) throws -> Bool {
        try context.fetchCount(FetchDescriptor<ImageConversionRecord>()) > 0
    }

    public func activate() {
        isActive = true
        windowControllerStorage?.activateForInstall()
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
        isActive = false
        await windowControllerStorage?.deactivateForUninstall()
        let cleanupTasks = Array(cleanupTasks.values)
        for task in cleanupTasks { task.cancel() }
        for task in cleanupTasks { await task.value }
        self.cleanupTasks.removeAll()
    }

    public func reconcileAfterImport() {
        windowControllerStorage?.reconcilePreferencesAfterImport()
    }

    // MARK: Clipboard-history contribution

    /// Stable id of the "Convert Image Format" clipboard action; commit
    /// routes back through `performClipboardAction` with this value.
    nonisolated static let convertClipboardActionID = "convertImageFormat"

    public func clipboardActions(for payload: PluginClipboardPayload) -> [PluginClipboardAction] {
        guard ClipboardConversionPolicy.isConvertible(payload) else { return [] }
        return [PluginClipboardAction(
            id: Self.convertClipboardActionID,
            titleKey: L10n.Key.clipboardActionConvertImage.rawValue,
            symbol: "arrow.left.arrow.right.square"
        )]
    }

    /// Preload the entry into the conversion basket and open the workspace
    /// window. A missing payload surfaces a failure toast and leaves the
    /// history window open; otherwise the window dismisses first so its
    /// slide-out doesn't fight the conversion panel's activation.
    public func performClipboardAction(
        id: String,
        payload: PluginClipboardPayload,
        context: PluginClipboardActionContext
    ) async {
        guard id == Self.convertClipboardActionID, isActive else { return }
        guard let items = ClipboardConversionPolicy.basketItems(for: payload) else {
            hostContext.showToast(.failure(L(hostContext, .imageConversionSourceMissing)))
            return
        }
        context.dismissHistoryWindow { [weak self] in
            self?.present(items: items)
        }
    }

    private func present(items: [ImageConversionBasketItem]) {
        guard isActive else { return }
        windowController.present(items: items)
    }

    private func toggleWindow() async {
        guard isActive else { return }
        await windowController.toggle()
    }
}
