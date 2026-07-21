import Foundation

/// A Script Plugin package on disk: a directory holding a validated manifest,
/// an ES-module bundle, and an optional icon.
///
/// This is the runtime's single new seam — the **plugin package boundary**. A
/// real directory goes in; the runtime produces row descriptors, Detail
/// content, action results, and capability side effects out, with real
/// JavaScriptCore underneath. Constructing a package validates the manifest but
/// reads no bundle and creates no context, so a refused package changes nothing.
public struct ScriptPluginPackage: Sendable, Equatable {
    public let directory: URL
    public let manifest: ScriptPluginManifest

    /// The bundle file URL derived from the manifest entry point.
    public var bundleURL: URL {
        directory.appendingPathComponent(manifest.entryPoint)
    }

    public var id: ScriptPluginID { manifest.id }

    public init(directory: URL, manifest: ScriptPluginManifest) {
        self.directory = directory
        self.manifest = manifest
    }

    /// Load and validate a package from its directory. Throws a typed
    /// ``ScriptManifestError`` on any manifest problem; side-effect-free.
    public static func load(fromDirectory directory: URL) throws -> ScriptPluginPackage {
        let manifest = try ScriptPluginManifest.load(fromDirectory: directory)
        return ScriptPluginPackage(directory: directory, manifest: manifest)
    }

    /// Read the ES-module bundle source. Deferred until context creation so a
    /// package with a missing bundle still validates (the runtime surfaces the
    /// read failure as an invocation error, not a load refusal).
    func readBundleSource() throws -> String {
        guard let data = try? Data(contentsOf: bundleURL),
              let source = String(data: data, encoding: .utf8) else {
            throw ScriptPluginError.bundleUnreadable(bundleURL.lastPathComponent)
        }
        return source
    }
}
