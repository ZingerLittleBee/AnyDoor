import Foundation

/// Spawn a subprocess, capture stdout/stderr, enforce a timeout.
///
/// Used for `defaults`, `killall`, `CGSession -suspend` and similar small CLI hops where
/// linking against the corresponding C API would be more complex than calling out.
enum ShellRunner {
    /// Launch a binary with args. Returns combined stdout/stderr. Throws on non-zero exit
    /// or timeout. Pass `timeout: nil` for interactive subprocesses that have no meaningful
    /// time budget (e.g. `screencapture -i`).
    static func run(
        _ path: String,
        args: [String] = [],
        timeout: TimeInterval? = 5
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()

            // Drain the pipe on a separate task so a child that writes more than the
            // OS pipe buffer (~64KB) keeps flowing instead of blocking on write()
            // forever. `readToEnd()` returns once the child closes its stdout/stderr
            // (normal exit OR terminate()), so it resolves on both paths below.
            // Capture the raw read fd (Sendable) and rebuild a non-owning FileHandle
            // inside the reader so nothing crosses the isolation boundary unsafely;
            // only this one task ever reads the fd.
            let readFD = pipe.fileHandleForReading.fileDescriptor
            let reader = Task.detached { () -> Data in
                let handle = FileHandle(fileDescriptor: readFD, closeOnDealloc: false)
                return (try? handle.readToEnd()) ?? Data()
            }

            // Timeout watchdog — only armed when a timeout is supplied.
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            while process.isRunning {
                if let deadline, Date() > deadline {
                    process.terminate()
                    let data = await reader.value
                    let output = String(data: data, encoding: .utf8) ?? ""
                    throw BuiltinError.shellFailed(code: -1, output: "timeout: \(output)")
                }
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }

            let data = await reader.value
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                throw BuiltinError.shellFailed(code: process.terminationStatus, output: output)
            }
            return output
        }.value
    }
}
