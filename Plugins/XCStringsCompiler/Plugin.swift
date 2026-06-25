import Foundation
import PackagePlugin

@main
struct XCStringsCompilerPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }

        let xcstrings = target.sourceFiles
            .filter { $0.url.pathExtension == "xcstrings" }

        return xcstrings.map { file in
            let inputURL = file.url
            let outputDirectory = context.pluginWorkDirectoryURL
                .appending(path: "xcstrings", directoryHint: .isDirectory)
                .appending(path: inputURL.deletingPathExtension().lastPathComponent, directoryHint: .isDirectory)
            return .prebuildCommand(
                displayName: "Compile \(inputURL.lastPathComponent)",
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "xcstringstool",
                    "compile",
                    inputURL.path,
                    "--output-directory",
                    outputDirectory.path
                ],
                outputFilesDirectory: outputDirectory
            )
        }
    }
}
