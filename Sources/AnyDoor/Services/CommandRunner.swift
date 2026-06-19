import Foundation

/// Result of a subprocess invocation; the controller cares about all three.
struct CommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var isSuccess: Bool { exitCode == 0 }
}

/// Abstract subprocess runner. The controller depends on this so tests can
/// substitute a fake runner instead of touching /usr/bin/hidutil.
protocol CommandRunner: Sendable {
    func run(_ path: String, args: [String], timeout: TimeInterval) async throws -> CommandResult
}

/// Default impl wrapping `Process`. Equivalent in spirit to ShellRunner but
/// returns CommandResult instead of throwing on non-zero exit — the caller
/// decides what is fatal vs informational.
struct DefaultCommandRunner: CommandRunner {
    func run(_ path: String, args: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            defer {
                if process.isRunning { process.terminate() }
            }

            // Drain both pipes concurrently so a child that fills either pipe
            // buffer (~64KB) keeps flowing instead of blocking on write() forever
            // (which would never let process.isRunning clear, tripping the timeout).
            // Capture the raw read fds (Sendable) and rebuild non-owning FileHandles
            // inside each reader; only that reader touches its fd.
            let outFD = outPipe.fileHandleForReading.fileDescriptor
            let errFD = errPipe.fileHandleForReading.fileDescriptor
            let outReader = Task.detached { () -> Data in
                let h = FileHandle(fileDescriptor: outFD, closeOnDealloc: false)
                return (try? h.readToEnd()) ?? Data()
            }
            let errReader = Task.detached { () -> Data in
                let h = FileHandle(fileDescriptor: errFD, closeOnDealloc: false)
                return (try? h.readToEnd()) ?? Data()
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Date() > deadline {
                    process.terminate()
                    // Await the readers before throwing so the pipes stay alive
                    // until both reads resolve (terminate() closes the child's
                    // write ends → EOF), closing the fd-recycle window. Matches
                    // ShellRunner's timeout path.
                    _ = await outReader.value
                    _ = await errReader.value
                    throw HyperKeyError.timeout
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }

            let stdout = String(data: await outReader.value, encoding: .utf8) ?? ""
            let stderr = String(data: await errReader.value, encoding: .utf8) ?? ""
            return CommandResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
        }.value
    }
}
