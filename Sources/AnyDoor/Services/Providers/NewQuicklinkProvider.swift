import Foundation

@MainActor
final class NewQuicklinkProvider: ActionProvider {
    let itemKey: BuiltinItem = .newQuicklink
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        SettingsOpener.shared.tryOpen(tab: .quicklinks)
    }
}
