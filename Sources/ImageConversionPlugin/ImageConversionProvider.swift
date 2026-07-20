import AppKit
import PluginInterface

@MainActor
final class ImageConversionProvider: ActionProvider {
    let itemKey: BuiltinItem = .imageConversion
    var permission: PermissionStatus { .notRequired }
    private let action: @MainActor () async -> Void

    init(action: @escaping @MainActor () async -> Void) {
        self.action = action
    }

    func run() async throws {
        await action()
    }
}
