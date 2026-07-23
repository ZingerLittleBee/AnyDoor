import AppKit
import Foundation
import ScriptPluginRuntime

/// Classifies an incoming `anydoor://` URL for the plugin-install command.
/// Pure and total so the accept/reject policy is unit-testable: the scheme's
/// only supported form is `anydoor://install-plugin?url=<https package zip>`,
/// and the package URL must be https — the same transport floor every other
/// plugin-URL boundary enforces (ADR-0009), applied before any network I/O.
enum PluginInstallURLParse: Equatable {
    /// A well-formed install command carrying the https package-zip URL.
    case install(packageURL: URL)
    /// Not an install command, or the `url` parameter is missing/unparsable.
    case invalid
    /// An install command whose package URL is not https (http, file, custom
    /// scheme). Distinct from `.invalid` so the user learns the actual rule.
    case insecure

    static func classify(_ url: URL) -> PluginInstallURLParse {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "anydoor",
              components.host?.lowercased() == "install-plugin",
              let packageString = components.queryItems?
                  .first(where: { $0.name == "url" })?.value,
              let packageURL = URL(string: packageString),
              let scheme = packageURL.scheme?.lowercased()
        else { return .invalid }
        guard scheme == "https" else { return .insecure }
        guard packageURL.host != nil else { return .invalid }
        return .install(packageURL: packageURL)
    }
}

/// What the user is asked to approve before a URL-delivered plugin installs:
/// identity, declared capability list, and where the package actually came from.
struct ScriptPluginInstallPrompt: Equatable, Sendable {
    let name: String
    let id: String
    let version: String
    let capabilities: [String]
    let originHost: String
}

/// Errors specific to the download half of a URL install; package validation
/// errors keep their `scriptSideloadFailureMessage` mapping.
enum PluginURLInstallError: Error, Equatable {
    case downloadFailed
    case tooLarge
}

/// Handles `anydoor://install-plugin?url=…`: download the package zip over
/// https, extract and validate it, ask the user to approve the plugin's
/// identity + declared capabilities + origin, then install through the same
/// `sideload` path a hand-picked folder uses. Every refusal (bad link, oversize
/// download, invalid package, duplicate id, declined prompt) changes nothing but
/// its own transient temp files.
@MainActor
final class ScriptPluginURLInstaller {
    static let shared = ScriptPluginURLInstaller()

    /// Hard cap on the downloaded archive. Real plugin packages are tens of
    /// kilobytes (a bundled JS file + manifest); anything near this bound is
    /// not a plugin.
    static let maxArchiveBytes = 20 * 1024 * 1024

    private let registry: @MainActor () -> ScriptPluginRegistry
    /// Downloads the package zip and returns a temp-file URL the installer owns.
    /// The sole network boundary, injected so tests replay a local fixture.
    private let download: @Sendable (URL) async throws -> URL
    /// Presents the approval prompt and returns the user's decision.
    private let confirmInstall: @MainActor (ScriptPluginInstallPrompt) async -> Bool
    private let presentToast: @MainActor (ToastStyle) -> Void
    private let languageCode: @MainActor () -> String?
    /// One URL install at a time; a second link while one is pending is refused
    /// with the shared transition-in-progress message.
    private var isHandling = false

    init(
        registry: @escaping @MainActor () -> ScriptPluginRegistry = { .shared },
        download: @escaping @Sendable (URL) async throws -> URL = ScriptPluginURLInstaller.downloadViaURLSession,
        confirmInstall: @escaping @MainActor (ScriptPluginInstallPrompt) async -> Bool = ScriptPluginURLInstaller.confirmViaAlert,
        presentToast: @escaping @MainActor (ToastStyle) -> Void = { ToastPresenter.shared.show($0) },
        languageCode: @escaping @MainActor () -> String? = {
            LocalizationManager.shared.effectiveLocale.language.languageCode?.identifier
        }
    ) {
        self.registry = registry
        self.download = download
        self.confirmInstall = confirmInstall
        self.presentToast = presentToast
        self.languageCode = languageCode
    }

    /// Entry point for `application(_:open:)`. Classifies synchronously and
    /// runs the install flow as a task; misuse surfaces a toast, never a crash.
    func handle(_ url: URL) {
        switch PluginInstallURLParse.classify(url) {
        case .invalid:
            presentToast(.failure(L(.pluginsUrlInstallInvalid)))
        case .insecure:
            presentToast(.failure(L(.pluginsUrlInstallInsecure)))
        case .install(let packageURL):
            guard !isHandling else {
                presentToast(.failure(L(.pluginsTransitionInProgress)))
                return
            }
            isHandling = true
            Task {
                defer { isHandling = false }
                await install(from: packageURL)
            }
        }
    }

    /// The full flow after a valid link. Awaitable for tests.
    func install(from packageURL: URL) async {
        let archive: URL
        do {
            archive = try await download(packageURL)
        } catch {
            presentToast(.failure(L(.pluginsUrlInstallDownloadFailed)))
            return
        }
        defer { try? FileManager.default.removeItem(at: archive) }

        let attributes = try? FileManager.default.attributesOfItem(atPath: archive.path)
        let archiveSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard archiveSize <= Self.maxArchiveBytes else {
            presentToast(.failure(L(.pluginsUrlInstallTooLarge)))
            return
        }

        do {
            let (tempRoot, packageRoot) = try ScriptPluginArchive.extract(zipURL: archive)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            // Validate before prompting, so the dialog only ever describes a
            // package that could actually install — and a duplicate id is
            // refused without bothering the user with an approval first.
            let package = try ScriptPluginPackage.load(fromDirectory: packageRoot)
            let manifest = package.manifest
            let reg = registry()
            if reg.isInstalled(package.id) || reg.isDevPlugin(package.id) {
                throw ScriptPluginError.duplicateID(package.id)
            }

            let prompt = ScriptPluginInstallPrompt(
                name: manifest.displayName(forLanguageCode: languageCode()),
                id: manifest.id.rawValue,
                version: manifest.version,
                capabilities: manifest.capabilities.map(\.rawValue).sorted(),
                originHost: packageURL.host ?? ""
            )
            guard await confirmInstall(prompt) else { return }

            let id = try reg.sideload(fromDirectory: packageRoot)
            let installedName = reg.installedManifests
                .first { $0.id == id }?
                .displayName(forLanguageCode: languageCode()) ?? prompt.name
            presentToast(.success(L(.pluginsUrlInstallSuccess, installedName)))
        } catch {
            presentToast(.failure(L(.pluginsSideloadFailed, scriptSideloadFailureMessage(error))))
        }
    }

    // MARK: - Production boundaries

    /// Download to a temp file via URLSession; any non-200 response is a
    /// download failure. The session's temp file is moved to a URL this
    /// installer owns, because URLSession reclaims its own location.
    private static func downloadViaURLSession(_ url: URL) async throws -> URL {
        let (location, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: location)
            throw PluginURLInstallError.downloadFailed
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-plugin-download-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: location, to: destination)
        return destination
    }

    /// The production approval dialog: name in the title; id, version, origin
    /// host, and the declared capability list in the body. The app is an
    /// accessory, so it must activate to put the alert in front of the browser
    /// the user clicked in.
    private static func confirmViaAlert(_ prompt: ScriptPluginInstallPrompt) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L(.pluginsUrlInstallConfirmTitle, prompt.name)
        let capabilities = prompt.capabilities.isEmpty
            ? L(.pluginsUrlInstallNoCapabilities)
            : prompt.capabilities.joined(separator: ", ")
        alert.informativeText = L(
            .pluginsUrlInstallConfirmBody,
            prompt.id, prompt.version, prompt.originHost, capabilities
        )
        alert.addButton(withTitle: L(.pluginsInstall))
        alert.addButton(withTitle: L(.pluginsUrlInstallCancel))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
