import Foundation

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
    }

    /// Extract `zipURL` into a fresh temporary directory and return both the
    /// temp root (the caller removes it when done — also on a thrown install
    /// error) and the located package root inside it.
    static func extract(zipURL: URL) throws -> (tempRoot: URL, packageRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("script-plugin-unzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        do {
            // ditto handles zip64 and preserves nothing we care about beyond the
            // file tree; its AppleDouble sidecars are ignored by root location
            // and by manifest/bundle reads.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zipURL.path, tempRoot.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
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
