import AppKit

@MainActor
final class ImageConversionProvider: ActionProvider {
    let itemKey: BuiltinItem = .imageConversion
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        await ImageConversionWindowController.shared.toggle()
    }
}
