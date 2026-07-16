import AppKit
import HostsHelperShared
import PluginInterface
import SwiftData

/// The Core's implementation of the host capabilities plugin modules may use
/// (`PluginHostServices`). One instance is built at launch and handed to every
/// Native Plugin; each method is a thin adapter onto the existing shared
/// service, so plugin behavior is identical to the pre-extraction direct calls.
@MainActor
final class CorePluginHost: PluginHostServices {
    let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Reads route through `LocalizationManager` (an `@Observable`), so a
    /// SwiftUI body evaluating this re-renders when the language changes.
    var effectiveLocale: Locale {
        LocalizationManager.shared.effectiveLocale
    }

    func localizedString(_ key: String) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: LocalizationManager.shared.bundle,
            value: key,
            comment: ""
        )
    }

    func showToast(_ toast: PluginToast) {
        switch toast {
        case .success(let message): ToastPresenter.shared.show(.success(message))
        case .info(let message): ToastPresenter.shared.show(.info(message))
        case .failure(let message): ToastPresenter.shared.show(.failure(message))
        }
    }

    func trackRegularWindow(_ window: NSWindow) {
        RegularWindowCoordinator.shared.track(window)
    }

    func pasteboardSelfWrite(_ body: (NSPasteboard) throws -> Void) rethrows {
        try ClipboardWatcher.selfWrite(body)
    }

    func runAppleScript(_ source: String) async throws -> String {
        try await AppleScriptRunner.run(source)
    }

    let privilegedHelper: any PrivilegedHelperAccess = CorePrivilegedHelper()
}

/// Adapter exposing the Core's shared privileged helper daemon to plugin
/// modules. Registration/approval delegate to `HelperManager`; release is
/// gated by `PrivilegedHelperRelease` so uninstalling Hosts never strands
/// forced Scheduled Shutdown (amended ADR-0005).
@MainActor
private final class CorePrivilegedHelper: PrivilegedHelperAccess {

    func readiness() -> PrivilegedHelperReadiness {
        switch HelperManager.shared.readiness() {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .unavailable: return .unavailable
        }
    }

    func ensureRegistered() -> Bool {
        HelperManager.shared.ensureRegistered()
    }

    func openApprovalSettings() {
        HelperManager.shared.openApprovalSettings()
    }

    nonisolated func writeHostsFile(_ content: String) async throws {
        try await PrivilegedHelperCall.run(
            makeError: { PrivilegedHelperCallError(message: $0) },
            request: { proxy, finish in
                proxy.writeHosts(content) { errorMessage in finish(errorMessage) }
            }
        )
    }

    func releaseIfUnneeded() throws {
        try PrivilegedHelperRelease(
            otherConsumersActive: { ScheduledShutdownService.shared.forced },
            unregister: { try HelperManager.shared.unregister() }
        ).releaseIfUnneeded()
    }
}
