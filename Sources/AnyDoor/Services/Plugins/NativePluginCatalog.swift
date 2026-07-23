import HostsPlugin
import ImageConversionPlugin
import PluginInterface
import SwiftData

/// The compile-time inventory of Native Plugins shipped with the app.
///
/// A registration owns both schema participation and runtime construction so
/// adding a plugin cannot update one launch phase while forgetting the other.
enum NativePluginCatalog {
    private struct Registration {
        let id: NativePluginID
        let modelSchemaTypes: [any PersistentModel.Type]
        let syncedDefaults: [PluginSyncedDefault]
        let makePlugin: @MainActor (any PluginHostServices) -> any NativePlugin
    }

    private static var registrations: [Registration] {
        [
            Registration(
                id: ImageConversionNativePlugin.pluginID,
                modelSchemaTypes: ImageConversionNativePlugin.modelSchemaTypes,
                syncedDefaults: ImageConversionNativePlugin.syncedDefaults,
                makePlugin: { ImageConversionNativePlugin(host: $0) }
            ),
            Registration(
                id: HostsNativePlugin.pluginID,
                modelSchemaTypes: HostsNativePlugin.modelSchemaTypes,
                syncedDefaults: HostsNativePlugin.syncedDefaults,
                makePlugin: { HostsNativePlugin(host: $0) }
            ),
        ]
    }

    nonisolated static var modelSchemaTypes: [any PersistentModel.Type] {
        registrations.flatMap(\.modelSchemaTypes)
    }

    /// Every plugin-declared portable preference, aggregated for the sync
    /// whitelist. Like the model schema, this is consulted independently of
    /// install state (plugin preferences are retained user data, ADR-0005).
    nonisolated static var syncedDefaults: [PluginSyncedDefault] {
        registrations.flatMap(\.syncedDefaults)
    }

    @MainActor
    static func makePlugins(host: any PluginHostServices) -> [any NativePlugin] {
        registrations.map { registration in
            let plugin = registration.makePlugin(host)
            precondition(
                plugin.id == registration.id,
                "Native Plugin registration id does not match its instance"
            )
            return plugin
        }
    }
}
