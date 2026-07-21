import PluginInterface
import SwiftData
import Testing

/// A Native Plugin with no optional contributions: only identity, claims,
/// providers, the usage-trace predicate, and deactivate are implemented.
@MainActor
private final class BarePlugin: NativePlugin {
    let id = NativePluginID(rawValue: "test.bare")
    let localizedName = "Bare"
    let localizedDescription = "A plugin with no optional contributions."
    let claimedCommands: Set<BuiltinItem> = [.imageConversion]
    let providers: [any BuiltinProvider] = []

    func hasUsageTrace(in context: ModelContext) throws -> Bool { false }
    func deactivate() async throws {}
}

/// Pins the `NativePlugin` protocol contract (ticket 013): the required
/// surface is identity + Claims + providers + usage trace + deactivate, and
/// every optional contribution defaults to empty — so adding the next plugin
/// stays mechanical and contributes nothing it didn't declare.
struct NativePluginContractTests {

    @Test @MainActor func optionalContributionsDefaultToEmpty() async {
        let plugin: any NativePlugin = BarePlugin()
        #expect(plugin.paletteOptionParents.isEmpty)
        let options = await plugin.paletteOptions(for: .imageConversion)
        #expect(options.isEmpty)
        #expect(plugin.paletteRowSources.isEmpty)
        #expect(plugin.panelPopover(for: .imageConversion) == nil)
        #expect(plugin.clipboardActions(for: .files([])).isEmpty)
        // The defaulted perform is a no-op: it must not trap and must not
        // touch the host context (dismissing here would close the wall).
        await plugin.performClipboardAction(
            id: "unknown",
            payload: .files([]),
            context: PluginClipboardActionContext(dismissHistoryWindow: { _ in
                Issue.record("the defaulted clipboard action must not dismiss the history window")
            })
        )
        // The schema surface is static (ADR-0005: collected before any
        // MainActor instance exists) and defaults to empty.
        #expect(BarePlugin.modelSchemaTypes.isEmpty)
        // Defaulted lifecycle hooks are no-ops; they must not trap.
        plugin.activate()
        plugin.reconcileAfterImport()
    }

    @Test func rowDescriptorIdentityIncludesCommitSemantics() {
        // `Source.pluginRow` will carry the descriptor by value (ADR-0007),
        // so Hashable identity must cover the declared commit semantics.
        let close = PluginRowDescriptor(id: "r", title: "Row", symbol: "circle", commit: .closeThenAct)
        let stay = PluginRowDescriptor(id: "r", title: "Row", symbol: "circle", commit: .stayOpen)
        #expect(close != stay)
        #expect(close == PluginRowDescriptor(id: "r", title: "Row", symbol: "circle", commit: .closeThenAct))
    }
}
