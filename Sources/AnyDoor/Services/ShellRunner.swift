import Foundation
import PluginInterface

/// Runs a binary through `ProcessRunner` and maps the outcome onto the
/// `BuiltinError` the panel providers already handle.
///
/// Used for `defaults`, `killall`, `CGSession -suspend` and similar small CLI hops where
/// linking against the corresponding C API would be more complex than calling out.
enum ShellRunner {
    /// Launch a binary with args and return its stdout. A non-zero exit throws
    /// `BuiltinError.shellFailed` with the exit code and stdout followed by stderr; a
    /// timeout throws it with code -1 and that output behind a "timeout: " prefix. A
    /// launch failure throws `SubprocessError.spawnFailed`, deliberately not a
    /// `BuiltinError`: `RegionCapture` relies on that to tell a tool that could not run
    /// from a cancelled selection. Pass `timeout: nil` for interactive subprocesses
    /// that have no meaningful time budget (e.g. `screencapture -i`).
    static func run(
        _ path: String,
        args: [String] = [],
        timeout: TimeInterval? = 5
    ) async throws -> String {
        let result = try await ProcessRunner().run(
            URL(fileURLWithPath: path),
            arguments: args,
            timeout: timeout.map { .seconds($0) }
        )
        let output = result.stdout + result.stderr
        if result.timedOut {
            throw BuiltinError.shellFailed(code: -1, output: "timeout: \(output)")
        }
        guard result.exit == 0 else {
            throw BuiltinError.shellFailed(code: result.exit, output: output)
        }
        return result.stdout
    }
}
