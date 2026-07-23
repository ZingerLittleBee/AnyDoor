import PluginInterface
import SwiftData
import Testing
@testable import AnyDoor

struct NativePluginCatalogTests {
    @Test @MainActor
    func catalogOwnsSchemaAndRuntimeConstruction() throws {
        let modelNames = NativePluginCatalog.modelSchemaTypes.map { String(describing: $0) }
        #expect(modelNames == ["ImageConversionRecord", "HostProfile"])

        let container = try ModelContainer(
            for: Schema(
                [KeyBinding.self, BuiltinPreference.self, Quicklink.self]
                    + NativePluginCatalog.modelSchemaTypes
            ),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let plugins = NativePluginCatalog.makePlugins(
            host: CorePluginHost(modelContainer: container)
        )
        let ids = plugins.map(\.id)

        #expect(ids == [
            NativePluginID(rawValue: "imageConversion"),
            NativePluginID(rawValue: "hosts"),
        ])
        #expect(ids.count == Set(ids).count)
    }
}
