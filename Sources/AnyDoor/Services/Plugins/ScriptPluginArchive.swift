import Foundation
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "plugins")

/// Extracts a Script Plugin package zip and locates the package root inside it,
/// so a user can sideload the `plugin-*.zip` a release workflow produced without
/// unzipping it first. Extraction is the only new capability; validation and
/// installation stay with `ScriptPluginPackage` / `ScriptPluginRegistry`, which
/// see a plain directory exactly as if the user had picked one.
enum ScriptPluginArchive {
    /// A refusal from the zip boundary, mapped to a localized message by
    /// `scriptSideloadFailureMessage`.
    enum ArchiveError: Error, Equatable {
        /// The file could not be extracted as a zip archive.
        case extractionFailed
        /// The archive extracted, but no package root (a directory holding
        /// `manifest.json`) was found at the top level or one wrapper deep.
        case packageRootNotFound
        /// ditto was still running when the extraction timeout ran out, and
        /// was terminated.
        case extractionTimedOut
    }

    /// How long ditto may run. A real package extracts in milliseconds, and a
    /// 20 MiB archive of incompressible files in a fraction of a second. This
    /// bounds time, not disk use: it ends a ditto stuck on its source (a file
    /// on an unresponsive volume, a cloud file that won't download) or one
    /// that runs away.
    static let extractionTimeout: Duration = .seconds(30)

    /// Extract `zipURL` into a fresh directory under `temporaryDirectory` and
    /// return both that temp root (the caller removes it when done — also on a
    /// thrown install error) and the located package root inside it.
    ///
    /// ditto runs through `ProcessRunner`, off the caller's actor. A run that
    /// outlives `timeout` is terminated and refused as `extractionTimedOut`;
    /// cancelling the calling task terminates ditto and throws
    /// `CancellationError`. Every refusal removes the temp root.
    static func extract(
        zipURL: URL,
        timeout: Duration = ScriptPluginArchive.extractionTimeout,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> (tempRoot: URL, packageRoot: URL) {
        let tempRoot = temporaryDirectory
            .appendingPathComponent("script-plugin-unzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        do {
            // ditto handles zip64 and preserves nothing we care about beyond the
            // file tree; its AppleDouble sidecars are ignored by root location
            // and by manifest/bundle reads.
            let result: SubprocessResult
            do {
                result = try await ProcessRunner().run(
                    URL(fileURLWithPath: "/usr/bin/ditto"),
                    arguments: ["-x", "-k", zipURL.path, tempRoot.path],
                    timeout: timeout
                )
            } catch let error as SubprocessError {
                logger.error("ditto could not launch: \(String(describing: error), privacy: .private)")
                throw ArchiveError.extractionFailed
            }
            if result.timedOut {
                throw ArchiveError.extractionTimedOut
            }
            guard result.exit == 0 else {
                logger.error(
                    "ditto exited with \(result.exit, privacy: .public): \(result.stderr, privacy: .private)"
                )
                throw ArchiveError.extractionFailed
            }
            let packageRoot = try locatePackageRoot(in: tempRoot)
            return (tempRoot, packageRoot)
        } catch {
            try? FileManager.default.removeItem(at: tempRoot)
            throw error
        }
    }

    /// Locate the directory holding `manifest.json`: the extraction root itself,
    /// or — when the zip wrapped the package in a single folder (zipping the
    /// `dist` directory instead of its contents) — that one wrapper. Finder's
    /// `__MACOSX` metadata directory and hidden files are ignored.
    static func locatePackageRoot(in directory: URL) throws -> URL {
        if hasManifest(directory) { return directory }
        let wrappers = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.lastPathComponent != "__MACOSX" }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        if wrappers.count == 1, let wrapper = wrappers.first, hasManifest(wrapper) {
            return wrapper
        }
        throw ArchiveError.packageRootNotFound
    }

    private static func hasManifest(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("manifest.json").path
        )
    }
}
