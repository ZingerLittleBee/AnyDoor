import Foundation
import PluginInterface
import ScriptPluginRuntime
import XCTest
@testable import AnyDoor

/// The zip-delivery half of Script Plugin distribution: extracting a
/// `plugin-*.zip` into the existing directory sideload path, and the
/// `anydoor://install-plugin` link that downloads one. Real zips (ditto-built,
/// like the release workflows produce), real registry, real JavaScriptCore;
/// the injected boundaries are the download transport and the approval prompt.
@MainActor
final class ScriptPluginZipInstallTests: XCTestCase {

    // MARK: - Harness (mirrors ScriptPluginRegistryTests.makeFixture)

    private struct Fixture {
        let registry: ScriptPluginRegistry
        let teardown: () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let defaults = makeTemporaryDefaults()
        let packagesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-install-packages-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = ScriptPluginFixture.makeStoreDirectory()
        let host = ScriptRuntimeHarness.makeCapabilityHost(
            spy: ScriptCapabilitySpy(),
            transport: RecordingFetchTransport(response: ScriptFetchResponse(status: 200, body: "{}")),
            storeDirectory: storeDirectory
        )
        let registry = ScriptPluginRegistry(
            runtime: ScriptPluginRuntime(capabilityHost: host),
            packagesDirectory: packagesDirectory,
            paletteExtensions: CommandPaletteExtensions(),
            defaults: defaults,
            languageCode: { "en" },
            refreshCommandPalette: {}
        )
        return Fixture(
            registry: registry,
            teardown: {
                try? FileManager.default.removeItem(at: packagesDirectory)
                try? FileManager.default.removeItem(at: storeDirectory)
            }
        )
    }

    private func fixturePackage(id: String, capabilities: [String] = []) throws -> URL {
        try ScriptPluginFixture.writePackage(
            id: id,
            name: "Zip Fixture",
            capabilities: capabilities,
            bundle: """
            anydoor.registerPlugin({ rows: function () { return []; } });
            """
        )
    }

    /// Zip a directory the way the release workflows do: `contentsAtRoot` puts
    /// manifest.json at the zip root; otherwise the directory itself becomes a
    /// single wrapper folder inside the archive.
    private func zipDirectory(_ directory: URL, contentsAtRoot: Bool) throws -> URL {
        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-fixture-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        var arguments = ["-c", "-k"]
        if !contentsAtRoot { arguments.append("--keepParent") }
        arguments += [directory.path, zip.path]
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ScriptPluginArchive.ArchiveError.extractionFailed
        }
        return zip
    }

    // MARK: - Package-root location

    func testLocatesRootWhenManifestAtTopLevel() throws {
        let package = try fixturePackage(id: "com.acme.root")
        let located = try ScriptPluginArchive.locatePackageRoot(in: package)
        XCTAssertEqual(located, package)
    }

    func testLocatesRootInsideSingleWrapperIgnoringMacOSXMetadata() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("wrapper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let package = try fixturePackage(id: "com.acme.wrapped")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let wrapper = parent.appendingPathComponent("dist", isDirectory: true)
        try FileManager.default.moveItem(at: package, to: wrapper)
        // Finder-zip artifacts that must not derail root location.
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("__MACOSX", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: parent.appendingPathComponent(".DS_Store"))

        let located = try ScriptPluginArchive.locatePackageRoot(in: parent)
        XCTAssertEqual(located.lastPathComponent, "dist")
    }

    func testMissingManifestAnywhereIsARefusal() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertThrowsError(try ScriptPluginArchive.locatePackageRoot(in: empty)) { error in
            XCTAssertEqual(
                error as? ScriptPluginArchive.ArchiveError, .packageRootNotFound
            )
        }
    }

    // MARK: - Zip sideload end to end

    func testSideloadFromZipWithContentsAtRootInstalls() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        let zip = try zipDirectory(try fixturePackage(id: "com.acme.zip-root"), contentsAtRoot: true)
        defer { try? FileManager.default.removeItem(at: zip) }

        let id = try await f.registry.sideload(fromZip: zip)
        XCTAssertEqual(id.rawValue, "com.acme.zip-root")
        XCTAssertTrue(f.registry.isInstalled(id))
        XCTAssertFalse(f.registry.isInstallingZip)
    }

    func testSideloadFromZipWithWrapperDirectoryInstalls() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        let zip = try zipDirectory(try fixturePackage(id: "com.acme.zip-wrapped"), contentsAtRoot: false)
        defer { try? FileManager.default.removeItem(at: zip) }

        let id = try await f.registry.sideload(fromZip: zip)
        XCTAssertTrue(f.registry.isInstalled(id))
    }

    func testSideloadFromNonZipFileIsARefusalWithoutSideEffects() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        let notAZip = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-zip-\(UUID().uuidString).zip")
        try Data("plain text".utf8).write(to: notAZip)
        defer { try? FileManager.default.removeItem(at: notAZip) }

        do {
            try await f.registry.sideload(fromZip: notAZip)
            XCTFail("expected extractionFailed")
        } catch {
            XCTAssertEqual(error as? ScriptPluginArchive.ArchiveError, .extractionFailed)
        }
        XCTAssertTrue(f.registry.installedManifests.isEmpty)
    }

    // MARK: - Stuck extraction

    /// A fresh directory that teardown removes.
    private func makeWorkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-install-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// A FIFO named like a zip, standing in for an archive on an unresponsive
    /// volume: ditto blocks opening it until a writer opens it too.
    /// Teardown releases a ditto still blocked on it before removing it, so a
    /// regression cannot leave ditto blocked for good.
    private func makeStuckZip(in directory: URL) throws -> URL {
        let fifo = directory.appendingPathComponent("stuck.zip")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        addTeardownBlock {
            _ = ScriptPluginZipInstallTests.releaseReader(of: fifo)
            try? FileManager.default.removeItem(at: fifo)
        }
        return fifo
    }

    /// Opens `fifo` for writing and closes it again, which lets a reader
    /// blocked opening it go on to read an empty file. False, harmlessly, when
    /// no reader is waiting.
    private nonisolated static func releaseReader(of fifo: URL) -> Bool {
        let descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    private func contents(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    func testExtractionThatOutlivesItsTimeoutIsRefused() async throws {
        let work = try makeWorkDirectory()
        let stuckZip = try makeStuckZip(in: work)
        let extractions = work.appendingPathComponent("extractions", isDirectory: true)

        do {
            _ = try await bounded(within: 10) {
                try await ScriptPluginArchive.extract(
                    zipURL: stuckZip, timeout: .milliseconds(300), temporaryDirectory: extractions
                )
            }
            XCTFail("expected extractionTimedOut")
        } catch {
            XCTAssertEqual(error as? ScriptPluginArchive.ArchiveError, .extractionTimedOut)
        }
        XCTAssertEqual(try contents(of: extractions), [], "the refusal removed its temp root")
        XCTAssertEqual(
            scriptSideloadFailureMessage(ScriptPluginArchive.ArchiveError.extractionTimedOut),
            L(.pluginsSideloadErrorUnzipTimedOut)
        )
    }

    /// The cancel waits until the temp root exists, so it lands either before
    /// ditto launches or while ditto is blocked; both must clean up.
    func testCancelledExtractionLeavesNothingBehind() async throws {
        let work = try makeWorkDirectory()
        let stuckZip = try makeStuckZip(in: work)
        let extractions = work.appendingPathComponent("extractions", isDirectory: true)
        let extractionsPath = extractions.path

        do {
            _ = try await bounded(within: 10, cancelWhen: {
                (try? FileManager.default.contentsOfDirectory(atPath: extractionsPath))?.isEmpty == false
            }) {
                try await ScriptPluginArchive.extract(zipURL: stuckZip, temporaryDirectory: extractions)
            }
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(try contents(of: extractions), [], "the cancelled extraction removed its temp root")
    }

    /// Settings disables its install button while a zip extracts, from the
    /// registry's state, and enables it again however the install ends.
    func testZipInstallIsInFlightUntilItsExtractionEnds() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        let stuckZip = try makeStuckZip(in: try makeWorkDirectory())
        let registry = f.registry

        let install = Task { try await registry.sideload(fromZip: stuckZip) }
        await waitUntil("the zip install to start") { registry.isInstallingZip }
        // Give the blocked ditto an empty archive, which it refuses.
        await waitUntil("ditto to open the archive") {
            ScriptPluginZipInstallTests.releaseReader(of: stuckZip)
        }
        do {
            _ = try await bounded(within: 10) { try await install.value }
            XCTFail("expected extractionFailed")
        } catch {
            XCTAssertEqual(error as? ScriptPluginArchive.ArchiveError, .extractionFailed)
        }
        XCTAssertFalse(registry.isInstallingZip)
    }

    // MARK: - Install-link classification

    func testClassifyAcceptsHTTPSInstallLink() throws {
        let url = try XCTUnwrap(URL(
            string: "anydoor://install-plugin?url=https%3A%2F%2Fexample.com%2Fplugin-x.zip"))
        XCTAssertEqual(
            PluginInstallURLParse.classify(url),
            .install(packageURL: URL(string: "https://example.com/plugin-x.zip")!)
        )
    }

    func testClassifyIsCaseInsensitiveOnSchemeAndHost() throws {
        let url = try XCTUnwrap(URL(
            string: "ANYDOOR://INSTALL-PLUGIN?url=HTTPS%3A%2F%2Fexample.com%2Fp.zip"))
        guard case .install = PluginInstallURLParse.classify(url) else {
            return XCTFail("uppercase scheme/host should still classify as install")
        }
    }

    func testClassifyRejectsNonHTTPSPackageURLsAsInsecure() throws {
        for package in ["http://example.com/p.zip", "file:///etc/hosts", "ftp://example.com/p.zip"] {
            let encoded = package.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            let url = try XCTUnwrap(URL(string: "anydoor://install-plugin?url=\(encoded)"))
            XCTAssertEqual(PluginInstallURLParse.classify(url), .insecure, package)
        }
    }

    func testClassifyRejectsMalformedLinksAsInvalid() throws {
        let cases = [
            "anydoor://install-plugin",                       // no url param
            "anydoor://install-plugin?url=",                  // empty url param
            "anydoor://install-plugin?url=not%20a%20url",     // no host
            "anydoor://something-else?url=https%3A%2F%2Fa.com/p.zip", // wrong command
            "https://install-plugin?url=https%3A%2F%2Fa.com/p.zip",   // wrong scheme
        ]
        for string in cases {
            let url = try XCTUnwrap(URL(string: string))
            XCTAssertEqual(PluginInstallURLParse.classify(url), .invalid, string)
        }
    }

    // MARK: - URL installer flow

    private func makeInstaller(
        registry: ScriptPluginRegistry,
        download: @escaping @Sendable (URL) async throws -> URL,
        confirm: @escaping @MainActor (ScriptPluginInstallPrompt) async -> Bool
    ) -> (ScriptPluginURLInstaller, () -> [ToastStyle], () -> [ScriptPluginInstallPrompt]) {
        var toasts: [ToastStyle] = []
        var prompts: [ScriptPluginInstallPrompt] = []
        let installer = ScriptPluginURLInstaller(
            registry: { registry },
            download: download,
            confirmInstall: { prompt in
                prompts.append(prompt)
                return await confirm(prompt)
            },
            presentToast: { toasts.append($0) },
            languageCode: { "en" }
        )
        return (installer, { toasts }, { prompts })
    }

    /// A download stub replaying a local fixture zip — copied per call because
    /// the installer deletes its downloaded file when done.
    private func stubDownload(of zip: URL) -> @Sendable (URL) async throws -> URL {
        { _ in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("download-\(UUID().uuidString).zip")
            try FileManager.default.copyItem(at: zip, to: copy)
            return copy
        }
    }

    func testURLInstallPromptsWithMetadataAndInstallsOnApproval() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        let zip = try zipDirectory(
            try fixturePackage(id: "com.acme.url", capabilities: ["fetch", "openURL"]),
            contentsAtRoot: true
        )
        defer { try? FileManager.default.removeItem(at: zip) }

        let (installer, toasts, prompts) = makeInstaller(
            registry: f.registry, download: stubDownload(of: zip), confirm: { _ in true })
        await installer.install(from: URL(string: "https://plugins.example.com/plugin-x.zip")!)

        let prompt = try XCTUnwrap(prompts().first)
        XCTAssertEqual(prompt.id, "com.acme.url")
        XCTAssertEqual(prompt.name, "Zip Fixture")
        XCTAssertEqual(prompt.version, "1.0.0")
        XCTAssertEqual(prompt.capabilities, ["fetch", "openURL"])
        XCTAssertEqual(prompt.originHost, "plugins.example.com")
        XCTAssertTrue(f.registry.isInstalled(ScriptPluginID("com.acme.url")))
        guard case .success = toasts().last else {
            return XCTFail("approval should end in a success toast, got \(toasts())")
        }
    }

    func testURLInstallDeclinedInstallsNothing() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        let zip = try zipDirectory(try fixturePackage(id: "com.acme.declined"), contentsAtRoot: true)
        defer { try? FileManager.default.removeItem(at: zip) }

        let (installer, toasts, _) = makeInstaller(
            registry: f.registry, download: stubDownload(of: zip), confirm: { _ in false })
        await installer.install(from: URL(string: "https://example.com/p.zip")!)

        XCTAssertTrue(f.registry.installedManifests.isEmpty)
        XCTAssertTrue(toasts().isEmpty, "a declined prompt is not an error")
    }

    func testURLInstallRefusesDuplicateBeforePrompting() async throws {
        let f = try makeFixture()
        defer { f.teardown() }
        let package = try fixturePackage(id: "com.acme.dup")
        try f.registry.sideload(fromDirectory: package)
        let zip = try zipDirectory(try fixturePackage(id: "com.acme.dup"), contentsAtRoot: true)
        defer { try? FileManager.default.removeItem(at: zip) }

        let (installer, toasts, prompts) = makeInstaller(
            registry: f.registry, download: stubDownload(of: zip), confirm: { _ in true })
        await installer.install(from: URL(string: "https://example.com/p.zip")!)

        XCTAssertTrue(prompts().isEmpty, "a duplicate id is refused before the prompt")
        guard case .failure = toasts().last else {
            return XCTFail("duplicate should surface a failure toast")
        }
    }

    func testURLInstallSurfacesDownloadFailure() async throws {
        let f = try makeFixture()
        defer { f.teardown() }

        let (installer, toasts, prompts) = makeInstaller(
            registry: f.registry,
            download: { _ in throw PluginURLInstallError.downloadFailed },
            confirm: { _ in true }
        )
        await installer.install(from: URL(string: "https://example.com/p.zip")!)

        XCTAssertTrue(prompts().isEmpty)
        guard case .failure = toasts().last else {
            return XCTFail("download failure should surface a failure toast")
        }
    }

    func testHandleSurfacesInvalidAndInsecureLinks() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        let (installer, toasts, _) = makeInstaller(
            registry: f.registry,
            download: { _ in throw PluginURLInstallError.downloadFailed },
            confirm: { _ in true }
        )

        installer.handle(try XCTUnwrap(URL(string: "anydoor://install-plugin")))
        installer.handle(try XCTUnwrap(
            URL(string: "anydoor://install-plugin?url=http%3A%2F%2Fa.com%2Fp.zip")))

        XCTAssertEqual(toasts().count, 2)
        XCTAssertEqual(toasts().map(\.message), [
            L(.pluginsUrlInstallInvalid), L(.pluginsUrlInstallInsecure),
        ])
    }
}
