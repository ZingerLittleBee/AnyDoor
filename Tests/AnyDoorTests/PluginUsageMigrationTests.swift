import SwiftData
import XCTest
import PluginInterface
@testable import AnyDoor
@testable import HostsPlugin
@testable import ImageConversionPlugin

/// Host-services double for the migration tests: only the privileged-helper
/// readiness is scripted (the registered-daemon usage trace), everything else
/// is a thin functional stand-in.
@MainActor
private final class MigrationPluginHost: PluginHostServices {
    final class ScriptedHelper: PrivilegedHelperAccess {
        var readinessValue: PrivilegedHelperReadiness = .unavailable
        private(set) var ensureRegisteredCalls = 0

        func readiness() -> PrivilegedHelperReadiness { readinessValue }

        func ensureRegistered() -> Bool {
            ensureRegisteredCalls += 1
            return readinessValue == .enabled
        }

        func openApprovalSettings() {}
        func writeHostsFile(_ content: String) async throws {}
        func releaseIfUnneeded() throws {}
    }

    let modelContainer: ModelContainer
    let helper = ScriptedHelper()

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

/// The one-time usage-trace migration (PRD Migration decision, seeder-test
/// pattern): an in-memory store seeded with/without usage traces must produce
/// the right installed set, exactly once, idempotently across relaunches.
@MainActor
final class PluginUsageMigrationTests: XCTestCase {

    private struct Fixture {
        let host: MigrationPluginHost
        let plugins: [any NativePlugin]
        let hostsPlugin: HostsNativePlugin
        let context: ModelContext
        let defaults: UserDefaults
        let teardown: () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "PluginUsageMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        let container = try ModelContainer(
            for: Schema(
                HostsNativePlugin.modelSchemaTypes
                    + ImageConversionNativePlugin.modelSchemaTypes
            ),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
        )
        let host = MigrationPluginHost(modelContainer: container)

        let writer = MockHostsWriter()
        let live: () -> String = { writer.lastWritten ?? "127.0.0.1 localhost\n" }
        let manager = HostsManager(
            writer: writer,
            backup: HostsBackupStore(
                backupDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString),
                readLiveHosts: live
            ),
            readLiveHosts: live
        )
        let hostsPlugin = HostsNativePlugin(host: host, manager: manager)
        let plugins: [any NativePlugin] = [
            ImageConversionNativePlugin(host: host),
            hostsPlugin,
        ]
        return Fixture(
            host: host,
            plugins: plugins,
            hostsPlugin: hostsPlugin,
            context: container.mainContext,
            defaults: defaults,
            teardown: { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    private func installedSet(in defaults: UserDefaults) -> [String]? {
        defaults.stringArray(forKey: PluginRegistry.installStateKey)
    }

    // MARK: - Trace evaluation

    func testFreshStoreMigratesToBothUninstalled() throws {
        let f = try makeFixture()
        defer { f.teardown() }

        PluginUsageMigration.runIfNeeded(plugins: f.plugins, in: f.context, defaults: f.defaults)

        XCTAssertEqual(installedSet(in: f.defaults), [],
                       "a fresh install starts with every plugin uninstalled")
        XCTAssertTrue(f.defaults.bool(forKey: PluginUsageMigration.migrationFlagKey))
    }

    func testHostProfileRowsInstallHosts() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.context.insert(HostProfile(name: "Dev"))
        try f.context.save()

        PluginUsageMigration.runIfNeeded(plugins: f.plugins, in: f.context, defaults: f.defaults)

        XCTAssertEqual(installedSet(in: f.defaults), ["hosts"])
    }

    func testRegisteredHelperAloneInstallsHosts() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        // No profile rows: the registered daemon alone must keep its managing UI.
        f.host.helper.readinessValue = .requiresApproval

        PluginUsageMigration.runIfNeeded(plugins: f.plugins, in: f.context, defaults: f.defaults)

        XCTAssertEqual(installedSet(in: f.defaults), ["hosts"])
    }

    func testConversionRecordsInstallImageConversion() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.context.insert(ImageConversionRecord(
            sourceName: "photo.png",
            sourceKind: .file,
            targetFormat: .jpeg,
            qualityPercent: 85,
            outputPath: "/tmp/photo.jpg"
        ))
        try f.context.save()

        PluginUsageMigration.runIfNeeded(plugins: f.plugins, in: f.context, defaults: f.defaults)

        XCTAssertEqual(installedSet(in: f.defaults), ["imageConversion"])
    }

    // MARK: - Idempotence

    func testSecondRunNeverChangesAMigratedSet() throws {
        let f = try makeFixture()
        defer { f.teardown() }

        PluginUsageMigration.runIfNeeded(plugins: f.plugins, in: f.context, defaults: f.defaults)
        XCTAssertEqual(installedSet(in: f.defaults), [])

        // New traces after the migration (a profile row, a registered helper)
        // must not re-trigger it — e.g. a Sparkle silent-update relaunch.
        f.context.insert(HostProfile(name: "Later"))
        try f.context.save()
        f.host.helper.readinessValue = .enabled

        PluginUsageMigration.runIfNeeded(plugins: f.plugins, in: f.context, defaults: f.defaults)

        XCTAssertEqual(installedSet(in: f.defaults), [],
                       "an already-migrated installed set survives relaunches unchanged")
    }

    func testPreexistingInstallStateWinsOverTraces() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        // Install state without the migration flag can only come from a
        // config-backup import on a not-yet-migrated launch; the explicit
        // selection beats the usage-trace inference.
        f.defaults.set(["imageConversion"], forKey: PluginRegistry.installStateKey)
        f.context.insert(HostProfile(name: "Dev"))
        try f.context.save()

        PluginUsageMigration.runIfNeeded(plugins: f.plugins, in: f.context, defaults: f.defaults)

        XCTAssertEqual(installedSet(in: f.defaults), ["imageConversion"])
        XCTAssertTrue(f.defaults.bool(forKey: PluginUsageMigration.migrationFlagKey))
    }

    // MARK: - Launch wiring

    func testMigratedInstalledSetActivatesThroughNormalBootstrap() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.host.helper.readinessValue = .requiresApproval

        // Launch sequence: migration first, then the registry bootstrap reads
        // the migrated state and activates the installed plugins.
        PluginUsageMigration.runIfNeeded(plugins: f.plugins, in: f.context, defaults: f.defaults)
        let registry = PluginRegistry()
        registry.bootstrap(plugins: f.plugins, defaults: f.defaults, hooks: .noop)

        XCTAssertTrue(registry.isInstalled(f.hostsPlugin.id))
        XCTAssertFalse(registry.isInstalled(ImageConversionNativePlugin.pluginID))
        XCTAssertEqual(f.host.helper.ensureRegisteredCalls, 1,
                       "activate must run for migrated-installed plugins")
    }
}
