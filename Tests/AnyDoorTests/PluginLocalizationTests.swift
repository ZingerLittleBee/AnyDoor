import AppKit
import SwiftData
import XCTest
@testable import AnyDoor
@testable import PluginInterface

/// Minimal host double for the plugin localization resolver: only the
/// localization surface matters, everything else is inert.
@MainActor
private final class StubLocalizationHost: PluginHostServices {
    private final class InertHelper: PrivilegedHelperAccess {
        func readiness() -> PrivilegedHelperReadiness { .unavailable }
        func ensureRegistered() -> Bool { false }
        func openApprovalSettings() {}
        func writeHostsFile(_ content: String) async throws {}
        func releaseIfUnneeded() throws {}
    }

    let modelContainer: ModelContainer
    var strings: [String: String] = [:]
    var locale = Locale(identifier: "en_US")

    init() throws {
        modelContainer = try ModelContainer(
            for: Schema([]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    var effectiveLocale: Locale { locale }
    func localizedString(_ key: String) -> String { strings[key] ?? key }
    func showToast(_ toast: PluginToast) {}
    func trackRegularWindow(_ window: NSWindow) {}
    func pasteboardSelfWrite(_ body: (NSPasteboard) throws -> Void) rethrows {
        try body(NSPasteboard.general)
    }
    func runAppleScript(_ source: String) async throws -> String { "" }
    let privilegedHelper: any PrivilegedHelperAccess = InertHelper()
}

/// The instance-scoped plugin localization path (`PluginHostContext` resolver
/// + the `@Observable` link every plugin `LocalizedText` relies on): key
/// resolution, format arguments, the context-free fallback, and the
/// language-switch invalidation that makes plugin views re-render live.
@MainActor
final class PluginLocalizationTests: XCTestCase {

    // MARK: - Resolver

    func testResolveFallsBackToRawKeyWithoutHostServices() {
        XCTAssertEqual(
            PluginHostContext.resolve(key: "plugin.hosts.name", arguments: [], services: nil),
            "plugin.hosts.name"
        )
    }

    func testResolveReturnsHostTemplateForPlainKeys() throws {
        let host = try StubLocalizationHost()
        host.strings["plugin.hosts.name"] = "Hosts 管理"
        XCTAssertEqual(
            PluginHostContext.resolve(key: "plugin.hosts.name", arguments: [], services: host),
            "Hosts 管理"
        )
    }

    func testResolveAppliesFormatArgumentsInHostLocale() throws {
        let host = try StubLocalizationHost()
        host.strings["hosts.profile.copyName"] = "%@ copy"
        host.strings["imageConversion.basket.count"] = "%d items"
        XCTAssertEqual(
            PluginHostContext.resolve(key: "hosts.profile.copyName", arguments: ["Dev"], services: host),
            "Dev copy"
        )
        XCTAssertEqual(
            PluginHostContext.resolve(key: "imageConversion.basket.count", arguments: [3], services: host),
            "3 items"
        )
    }

    func testContextsKeepTheirHostsIsolated() throws {
        let firstHost = try StubLocalizationHost()
        firstHost.strings["plugin.hosts.name"] = "First"
        let secondHost = try StubLocalizationHost()
        secondHost.strings["plugin.hosts.name"] = "Second"
        let first = PluginHostContext(services: firstHost)
        let second = PluginHostContext(services: secondHost)

        XCTAssertEqual(first.localizedString("plugin.hosts.name"), "First")
        XCTAssertEqual(second.localizedString("plugin.hosts.name"), "Second")
    }

    // MARK: - Language-switch reactivity

    /// The link `PluginLocalizedText` depends on: reading the manager's
    /// locale-scoped `bundle` (what every localized-string lookup does) must
    /// register an observation that fires when the language preference
    /// changes, so SwiftUI re-renders plugin views on a switch.
    func testBundleReadIsInvalidatedByLanguageSwitch() throws {
        let suiteName = "PluginLocalizationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = LocalizationManager(defaults: defaults)
        manager.preference = .en

        let fired = expectation(description: "bundle observation fired")
        withObservationTracking {
            _ = manager.bundle
        } onChange: {
            fired.fulfill()
        }
        manager.preference = .zh
        wait(for: [fired], timeout: 1)
    }

    /// Same chain one hop further out: the Core's host-services adapter must
    /// route `effectiveLocale` reads through the observable manager, so a
    /// plugin view body reading it re-renders on a language switch.
    func testCorePluginHostLocaleReadIsInvalidatedByLanguageSwitch() throws {
        let container = try ModelContainer(
            for: Schema([]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let host = CorePluginHost(modelContainer: container)
        let previous = LocalizationManager.shared.preference
        defer { LocalizationManager.shared.preference = previous }
        LocalizationManager.shared.preference = .en

        let fired = expectation(description: "locale observation fired")
        withObservationTracking {
            _ = host.effectiveLocale
        } onChange: {
            fired.fulfill()
        }
        LocalizationManager.shared.preference = .zh
        wait(for: [fired], timeout: 1)
    }
}
