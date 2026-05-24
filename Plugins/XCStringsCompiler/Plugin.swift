import Foundation
import PackagePlugin

@main
struct XCStringsCompilerPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }

        let xcstrings = target.sourceFiles
            .filter { $0.path.extension == "xcstrings" }

        return xcstrings.map { file in
            let inputPath = file.path
            let outputDirectory = context.pluginWorkDirectory
                .appending(["xcstrings", inputPath.stem])
            return .prebuildCommand(
                displayName: "Compile \(inputPath.lastComponent)",
                executable: Path("/usr/bin/xcrun"),
                arguments: [
                    "xcstringstool",
                    "compile",
                    inputPath.string,
                    "--output-directory",
                    outputDirectory.string
                ],
                outputFilesDirectory: outputDirectory
            )
        }
    }
}
