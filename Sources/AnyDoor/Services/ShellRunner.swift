import Foundation

/// Spawn a subprocess, capture stdout/stderr, enforce a timeout.
///
/// Used for `defaults`, `killall`, `CGSession -suspend` and similar small CLI hops where
/// linking against the corresponding C API would be more complex than calling out.
enum ShellRunner {
    /// Launch a binary with args. Returns combined stdout/stderr. Throws on non-zero exit
    /// or timeout (default 5 seconds).
    static func run(
        _ path: String,
        args: [String] = [],
        timeout: TimeInterval = 5
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()

            // Timeout watchdog
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() > deadline {
                    process.terminate()
                    let data = try? pipe.fileHandleForReading.readToEnd()
                    let output = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    throw BuiltinError.shellFailed(code: -1, output: "timeout: \(output)")
                }
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }

            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                throw BuiltinError.shellFailed(code: process.terminationStatus, output: output)
            }
            return output
        }.value
    }
}
