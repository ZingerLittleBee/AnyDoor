import Foundation
import Darwin
import os

// MARK: - Subprocess runner protocol

protocol SubprocessRunning: Sendable {
    func run(
        path: String,
        args: [String],
        timeout: Duration
    ) async throws -> SubprocessResult
}

struct SubprocessResult: Sendable, Equatable {
    let stdout: String
    let stderr: String
    let exit: Int32
    let timedOut: Bool
}

enum SubprocessError: Error, Equatable {
    case spawnFailed(String)
}

// MARK: - Scanner protocol

protocol PortScanning: Sendable {
    func scanTCPListening() async throws -> [PortRecord]
    func kill(pid: pid_t, signal: Int32) -> SignalResult
}

enum PortScanError: Error, Equatable {
    case lsofTimeout
    case lsofFailed(exitCode: Int32, stderr: String)
    case parseFailed(line: String)
}

// MARK: - PortScanner actor (skeleton — implemented across later tasks)

actor PortScanner: PortScanning {
    private let runner: any SubprocessRunning
    private static let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "PortScanner")

    init(runner: any SubprocessRunning = LsofRunner()) {
        self.runner = runner
    }

    func scanTCPListening() async throws -> [PortRecord] {
        // Implemented in Task 7.
        return []
    }

    nonisolated func kill(pid: pid_t, signal: Int32) -> SignalResult {
        if Darwin.kill(pid, signal) == 0 { return .success }
        let code = POSIXErrorCode(rawValue: errno) ?? .EINVAL
        return .failure(code)
    }
}

// MARK: - LsofRunner placeholder (real implementation lands in Task 8)

struct LsofRunner: SubprocessRunning {
    func run(path: String, args: [String], timeout: Duration) async throws -> SubprocessResult {
        // Placeholder; replaced in Task 8.
        return SubprocessResult(stdout: "", stderr: "", exit: 0, timedOut: false)
    }
}
