import SwiftData
import SwiftUI
import XCTest
import PluginInterface
@testable import AnyDoor
@testable import HostsPlugin

/// Test double for the host services handed to the real `HostsNativePlugin`.
/// Only the privileged-helper capability is scripted (the sanctioned external
/// boundary besides the hosts writer); everything else is a thin functional
/// stand-in.
@MainActor
private final class RecordingPluginHost: PluginHostServices {
    final class RecordingHelper: PrivilegedHelperAccess {
        var readinessValue: PrivilegedHelperReadiness = .unavailable
        private(set) var ensureRegisteredCalls = 0
        private(set) var releaseCalls = 0
        var releaseError: Error?

        func readiness() -> PrivilegedHelperReadiness { readinessValue }

        func ensureRegistered() -> Bool {
            ensureRegisteredCalls += 1
            return readinessValue == .enabled
        }

        func openApprovalSettings() {}

        func writeHostsFile(_ content: String) async throws {}

        func releaseIfUnneeded() throws {
            if let releaseError { throw releaseError }
            releaseCalls += 1
        }
    }

    let modelContainer: ModelContainer
    let helper = RecordingHelper()

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    var effectiveLocale: Locale { Locale(identifier: "en_US") }
    func localizedString(_ key: String) -> String { key }
    func showToast(_ toast: PluginToast) {}
    func trackRegularWindow(_ window: NSWindow) {}
    func pasteboardSelfWrite(_ body: (NSPasteboard) throws -> Void) rethrows {
        try body(NSPasteboard.general)
    }
    func runAppleScript(_ source: String) async throws -> String { "" }
    var privilegedHelper: any PrivilegedHelperAccess { helper }
}

/// Registry lifecycle for the real Hosts plugin (PRD Testing Decisions):
/// install surfaces appear; uninstall never touches the hosts file or
/// prompts for authorization — active profiles stay active and their managed
/// block stays in `/etc/hosts` (ADR-0005 addendum 2026-07-17) — and only
/// releases the shared helper (a failed release aborts the uninstall
/// transactionally, leaving the plugin fully installed). `MockHostsWriter`
/// is the sanctioned boundary double.
@MainActor
final class HostsPluginLifecycleTests: XCTestCase {

    private struct Fixture {
        let plugin: HostsNativePlugin
        let manager: HostsManager
        let writer: MockHostsWriter
        let host: RecordingPluginHost
        let registry: PluginRegistry
        let palette: CommandPaletteExtensions
        let defaults: UserDefaults
        let teardown: () -> Void
    }

    private func makeFixture(
        debounceInterval: Duration = .milliseconds(1)
    ) throws -> Fixture {
        let suiteName = "HostsPluginLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        let container = try ModelContainer(
            for: Schema(HostsNativePlugin.modelSchemaTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
        )
        let writer = MockHostsWriter()
        // Stateful live read: each write becomes the new file content, so the
        // no-op skip behaves as it would against the real /etc/hosts.
        let live: () -> String = { writer.lastWritten ?? "127.0.0.1 localhost\n" }
        let manager = HostsManager(
            writer: writer,
            backup: HostsBackupStore(
                backupDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString),
                readLiveHosts: live
            ),
            readLiveHosts: live,
            debounceInterval: debounceInterval
        )
        let host = RecordingPluginHost(modelContainer: container)
        let plugin = HostsNativePlugin(host: host, manager: manager)

        let palette = CommandPaletteExtensions()
        let registry = PluginRegistry()
        registry.bootstrap(
            plugins: [plugin],
            defaults: defaults,
            hooks: PluginRegistry.SurfaceHooks(
                registerProviders: { _ in },
                unregisterProviders: { _ in },
                registerPaletteContributions: { palette.registerContributions(of: $0) },
                unregisterPaletteContributions: { palette.unregisterContributions(of: $0) },
                refreshSurfaces: {}
            )
        )
        return Fixture(
            plugin: plugin, manager: manager, writer: writer, host: host,
            registry: registry, palette: palette, defaults: defaults,
            teardown: { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    // MARK: - Contract

    func testClaimsAndContributions() throws {
        let f = try makeFixture()
        defer { f.teardown() }

        XCTAssertEqual(f.plugin.claimedCommands, [.hostsManager])
        XCTAssertTrue(f.plugin.providers.isEmpty, "submenu-kind commands have no provider")
        XCTAssertEqual(f.plugin.paletteOptionParents, [.hostsManager])
        XCTAssertEqual(f.plugin.paletteRowSources.map(\.id), [HostProfileRowSource.sourceID])
        XCTAssertNotNil(f.plugin.panelPopover(for: .hostsManager))
        XCTAssertNil(f.plugin.panelPopover(for: .bluetoothBattery))
        XCTAssertEqual(
            HostsNativePlugin.modelSchemaTypes.map { String(describing: $0) },
            ["HostProfile"]
        )
    }

    // MARK: - Install

    func testInstallActivatesManagerRegistersHelperAndPaletteSurfaces() throws {
        let f = try makeFixture()
        defer { f.teardown() }

        XCTAssertFalse(f.palette.isOptionParent(.hostsManager))

        f.registry.install(f.plugin.id)

        XCTAssertTrue(f.registry.isInstalled(f.plugin.id))
        XCTAssertTrue(f.registry.isAvailable(.hostsManager))
        XCTAssertEqual(f.host.helper.ensureRegisteredCalls, 1,
                       "helper registration is an install-time act")
        XCTAssertTrue(f.palette.isOptionParent(.hostsManager))
        XCTAssertTrue(f.palette.listsAtRoot(.hostsManager))
        XCTAssertNotNil(f.palette.rowSource(withID: HostProfileRowSource.sourceID))
        XCTAssertNotNil(f.registry.panelPopover(for: .hostsManager))
    }

    // MARK: - Uninstall (side-effect-free on the hosts file)

    func testUninstallLeavesActiveProfilesAndHostsFileUntouched() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.install(f.plugin.id)
        f.manager.createProfile(name: "Dev", content: "1.2.3.4 dev.example.com")
        await f.manager.setActive(f.manager.profiles[0], true)
        XCTAssertEqual(f.writer.writeCount, 1)
        XCTAssertTrue(try XCTUnwrap(f.writer.lastWritten).contains(HostsFile.beginMarker))

        try await f.registry.uninstall(f.plugin.id)

        XCTAssertFalse(f.registry.isInstalled(f.plugin.id))
        // The hosts file is never touched: no write, no auth prompt, and the
        // managed block (the active entries) stays in effect.
        XCTAssertEqual(f.writer.writeCount, 1,
                       "uninstall must never write the hosts file")
        XCTAssertTrue(try XCTUnwrap(f.writer.lastWritten).contains(HostsFile.beginMarker))
        // Rows are retained and the activation state survives untouched.
        XCTAssertEqual(f.manager.profiles.count, 1)
        XCTAssertTrue(f.manager.profiles[0].isActive)
        XCTAssertEqual(f.host.helper.releaseCalls, 1)
        // Surfaces are gone.
        XCTAssertFalse(f.palette.isOptionParent(.hostsManager))
        XCTAssertNil(f.palette.rowSource(withID: HostProfileRowSource.sourceID))
        XCTAssertNil(f.registry.panelPopover(for: .hostsManager))
        XCTAssertFalse(f.registry.isAvailable(.hostsManager))
    }

    func testUninstallWithoutActiveProfilesNeverWrites() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.install(f.plugin.id)
        f.manager.createProfile(name: "Dev", content: "1.2.3.4 dev")

        try await f.registry.uninstall(f.plugin.id)

        XCTAssertEqual(f.writer.writeCount, 0,
                       "uninstall never writes the hosts file or prompts for auth")
        XCTAssertEqual(f.host.helper.releaseCalls, 1)
        XCTAssertFalse(f.registry.isInstalled(f.plugin.id))
    }

    func testUninstallCancelsPendingApplyBeforeReleasingHelper() async throws {
        let f = try makeFixture(debounceInterval: .milliseconds(100))
        defer { f.teardown() }
        f.registry.install(f.plugin.id)
        f.manager.createProfile(name: "Dev", content: "1.2.3.4 dev")
        let profileID = f.manager.profiles[0].id

        let activation = Task { @MainActor in
            if let profile = f.manager.profiles.first(where: { $0.id == profileID }) {
                await f.manager.setActive(profile, true)
            }
        }
        try await Task.sleep(for: .milliseconds(20))

        try await f.registry.uninstall(f.plugin.id)
        await activation.value

        XCTAssertEqual(f.writer.writeCount, 0)
        XCTAssertEqual(f.host.helper.releaseCalls, 1)
        XCTAssertFalse(f.manager.profiles[0].isActive)
    }

    /// A failed helper release is the only remaining abort path: the
    /// uninstall rethrows and the plugin stays fully installed with every
    /// surface intact — and the hosts file still untouched.
    func testFailedHelperReleaseAbortsUninstallLeavingHostsUntouched() async throws {
        struct ReleaseFailure: Error {}
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.install(f.plugin.id)
        f.manager.createProfile(name: "Dev", content: "1.2.3.4 dev.example.com")
        await f.manager.setActive(f.manager.profiles[0], true)
        XCTAssertEqual(f.writer.writeCount, 1)
        f.host.helper.releaseError = ReleaseFailure()

        do {
            try await f.registry.uninstall(f.plugin.id)
            XCTFail("uninstall must rethrow the failed helper release")
        } catch {
            XCTAssertTrue(error is ReleaseFailure)
        }

        // Still fully installed, every surface intact.
        XCTAssertTrue(f.registry.isInstalled(f.plugin.id))
        XCTAssertTrue(f.registry.isAvailable(.hostsManager))
        XCTAssertTrue(f.palette.isOptionParent(.hostsManager))
        XCTAssertNotNil(f.palette.rowSource(withID: HostProfileRowSource.sourceID))
        XCTAssertNotNil(f.registry.panelPopover(for: .hostsManager))
        // The hosts file and the activation state are untouched either way.
        XCTAssertEqual(f.writer.writeCount, 1)
        XCTAssertTrue(try XCTUnwrap(f.writer.lastWritten).contains(HostsFile.beginMarker))
        XCTAssertEqual(f.manager.profiles.count, 1)
        XCTAssertTrue(f.manager.profiles[0].isActive)
        XCTAssertEqual(f.host.helper.releaseCalls, 0,
                       "the failed release never counts as a release")

        f.manager.createProfile(name: "Still operational", content: "1.2.3.4 active")
        let restoredProfile = try XCTUnwrap(f.manager.profiles.last)
        await f.manager.setActive(restoredProfile, true)
        XCTAssertEqual(f.writer.writeCount, 2,
                       "a failed uninstall must restore the manager's mutation lifecycle")
    }

    // MARK: - Reinstall

    func testReinstallShowsProfilesStillActiveWithAllSurfacesBack() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.install(f.plugin.id)
        f.manager.createProfile(name: "Dev", content: "1.2.3.4 dev")
        await f.manager.setActive(f.manager.profiles[0], true)
        try await f.registry.uninstall(f.plugin.id)

        f.registry.install(f.plugin.id)

        XCTAssertTrue(f.registry.isInstalled(f.plugin.id))
        XCTAssertTrue(f.registry.isAvailable(.hostsManager))
        XCTAssertTrue(f.palette.isOptionParent(.hostsManager))
        XCTAssertNotNil(f.palette.rowSource(withID: HostProfileRowSource.sourceID))
        // The retained row is back on every surface, still active (US8: the
        // exact previous setup) — no re-authorization, no hosts write.
        XCTAssertEqual(f.manager.profiles.map(\.name), ["Dev"])
        XCTAssertTrue(f.manager.profiles[0].isActive)
        XCTAssertEqual(f.writer.writeCount, 1)
        let rows = f.plugin.paletteRowSources[0].rows()
        XCTAssertEqual(rows.map(\.title), ["Dev"])
        XCTAssertEqual(rows.map(\.symbol), ["checkmark.circle.fill"])
    }

    // MARK: - Palette options

    func testPaletteOptionsListProfilesWithCheckmarkPlusEditRow() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.registry.install(f.plugin.id)
        f.manager.createProfile(name: "Dev", content: "1.2.3.4 dev")
        await f.manager.setActive(f.manager.profiles[0], true)
        f.manager.createProfile(name: "Prod", content: "5.6.7.8 prod")

        let builtOptions = await f.palette.options(for: .hostsManager)
        let options = try XCTUnwrap(builtOptions)

        XCTAssertEqual(Array(options.map(\.title).dropLast()), ["Dev", "Prod"])
        XCTAssertEqual(options.map(\.isChecked), [true, false, false])
        XCTAssertEqual(options.last?.id, HostsPaletteOptions.editOptionID)

        // Committing a profile option toggles it through the plugin hook.
        await options[0].perform()
        XCTAssertFalse(f.manager.profiles[0].isActive)
    }

    // MARK: - Backup import

    func testImportInstallingHostsActivatesLikeHandsOnInstall() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        XCTAssertFalse(f.registry.isInstalled(f.plugin.id))

        // A backup exported from a machine with Hosts installed: the settings
        // import wrote the set; reconcile must behave like a hands-on install.
        f.defaults.set(["hosts"], forKey: PluginRegistry.installStateKey)
        await f.registry.reconcileAfterImport()

        XCTAssertTrue(f.registry.isInstalled(f.plugin.id))
        XCTAssertEqual(f.host.helper.ensureRegisteredCalls, 1,
                       "importing an installed plugin runs activate, not just a defaults write")
        XCTAssertTrue(f.palette.isOptionParent(.hostsManager))
        XCTAssertNotNil(f.registry.panelPopover(for: .hostsManager))
    }

    func testImportWithoutHostsNeverTouchesTheHelper() async throws {
        let f = try makeFixture()
        defer { f.teardown() }

        f.defaults.set([String](), forKey: PluginRegistry.installStateKey)
        await f.registry.reconcileAfterImport()

        XCTAssertFalse(f.registry.isInstalled(f.plugin.id))
        XCTAssertEqual(f.host.helper.ensureRegisteredCalls, 0,
                       "an import that doesn't install Hosts never touches helper registration")
    }

    // MARK: - Usage trace (migration input)

    func testUsageTraceSeesProfileRowsOrRegisteredHelper() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        let context = f.host.modelContainer.mainContext

        XCTAssertFalse(try f.plugin.hasUsageTrace(in: context))

        f.host.helper.readinessValue = .requiresApproval
        XCTAssertTrue(try f.plugin.hasUsageTrace(in: context),
                      "a registered daemon needs its managing UI even with no profiles")

        f.host.helper.readinessValue = .unavailable
        context.insert(HostProfile(name: "Dev"))
        try context.save()
        XCTAssertTrue(try f.plugin.hasUsageTrace(in: context))
    }
}
