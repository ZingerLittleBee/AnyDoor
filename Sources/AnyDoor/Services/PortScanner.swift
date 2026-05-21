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
        let result = try await runner.run(
            path: "/usr/sbin/lsof",
            args: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pPcntL", "+c", "0"],
            timeout: .seconds(3)
        )

        if result.timedOut { throw PortScanError.lsofTimeout }

        // lsof returns exit 1 with empty stdout AND empty stderr when there is
        // no matching open file. Treat that as a successful empty scan.
        if result.exit == 1 && result.stdout.isEmpty && result.stderr.isEmpty {
            return []
        }
        // Non-zero exit with any output on stderr (or stdout) is a real failure.
        if result.exit != 0 {
            throw PortScanError.lsofFailed(exitCode: result.exit, stderr: result.stderr)
        }

        var records = try parseLsofOutput(result.stdout)
        records = enrichWithProcArgs(records)
        return records
    }

    /// Enriches each record's `executablePath` and `commandLine` via sysctl.
    /// One sysctl call per unique pid; failures are silent (record keeps lsof's data).
    private func enrichWithProcArgs(_ records: [PortRecord]) -> [PortRecord] {
        var cache: [pid_t: (path: String?, command: String?)] = [:]
        return records.map { r in
            if cache[r.pid] == nil {
                cache[r.pid] = parseProcArgs(forPid: r.pid)
            }
            let info = cache[r.pid] ?? (nil, nil)
            return PortRecord(
                port: r.port,
                pid: r.pid,
                processName: r.processName,
                executablePath: info.path,
                commandLine: info.command,
                binds: r.binds
            )
        }
    }

    nonisolated func kill(pid: pid_t, signal: Int32) -> SignalResult {
        if Darwin.kill(pid, signal) == 0 { return .success }
        let code = POSIXErrorCode(rawValue: errno) ?? .EINVAL
        return .failure(code)
    }
}

// MARK: - LsofRunner

struct LsofRunner: SubprocessRunning {
    func run(path: String, args: [String], timeout: Duration) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() }
        catch { throw SubprocessError.spawnFailed("\(error)") }

        // OSAllocatedUnfairLock<Bool> — no new dependency, watchdog and
        // result-builder both read/write through .withLock.
        let timedOut = OSAllocatedUnfairLock<Bool>(initialState: false)

        return await withTaskCancellationHandler {
            // Drain pipes concurrently so the kernel buffer never fills.
            async let outData: Data = readAll(outPipe.fileHandleForReading)
            async let errData: Data = readAll(errPipe.fileHandleForReading)

            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                if process.isRunning {
                    timedOut.withLock { $0 = true }
                    process.terminate()
                }
            }

            let out = await outData
            let err = await errData
            watchdog.cancel()
            process.waitUntilExit()

            return SubprocessResult(
                stdout: String(data: out, encoding: .utf8) ?? "",
                stderr: String(data: err, encoding: .utf8) ?? "",
                exit: process.terminationStatus,
                timedOut: timedOut.withLock { $0 }
            )
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private func readAll(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
        DispatchQueue.global().async {
            let data = (try? handle.readToEnd()) ?? Data()
            cont.resume(returning: data)
        }
    }
}

// MARK: - lsof -F output parser

/// Parses the output of `lsof -nP -iTCP -sTCP:LISTEN -F pPcntL +c 0`.
///
/// Field format reference (from `lsof -F?`):
///   p = process id, c = command name, L = login name (process records)
///   f = file descriptor (starts a new file record), P = protocol, t = file type
///   (IPv4/IPv6), n = comment/name ("addr:port")
///
/// Each line is `<fieldChar><value>`. `p` starts a new process group; `f` starts
/// a new file within the current process group.
func parseLsofOutput(_ raw: String) throws -> [PortRecord] {
    struct PartialFile {
        var family: AddressFamily?
        var name: String?
        var protocolName: String?
    }
    struct PartialProcess {
        var pid: pid_t?
        var command: String = ""
        var files: [PartialFile] = []
    }

    var partials: [PartialProcess] = []
    var currentProcess: PartialProcess? = nil
    var currentFile: PartialFile? = nil

    func flushFile() {
        if let file = currentFile, currentProcess != nil {
            currentProcess!.files.append(file)
        }
        currentFile = nil
    }
    func flushProcess() {
        flushFile()
        if let proc = currentProcess { partials.append(proc) }
        currentProcess = nil
    }

    for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let first = rawLine.first else { continue }
        let value = String(rawLine.dropFirst())

        switch first {
        case "p":
            flushProcess()
            currentProcess = PartialProcess(pid: pid_t(value), command: "", files: [])
        case "c":
            if currentProcess != nil { currentProcess!.command = decodeLsofEscapes(value) }
        case "L":
            break // login name unused
        case "f":
            flushFile()
            currentFile = PartialFile()
        case "P":
            if currentFile != nil { currentFile!.protocolName = value }
        case "t":
            if currentFile != nil { currentFile!.family = AddressFamily(rawValue: value) }
        case "n":
            if currentFile != nil { currentFile!.name = value }
        default:
            break // unknown field — ignore for forward-compat
        }
    }
    flushProcess()

    // Group by (pid, port). Within a group, accumulate distinct binds.
    struct Key: Hashable { let pid: pid_t; let port: UInt16 }
    var groups: [Key: (processName: String, binds: [PortBind])] = [:]
    var keyOrder: [Key] = []

    for proc in partials {
        guard let pid = proc.pid else { continue }
        for file in proc.files {
            guard let name = file.name,
                  let (address, port) = parseAddressPort(name),
                  let family = file.family else { continue }
            let key = Key(pid: pid, port: port)
            let bind = PortBind(address: address, family: family)
            if var existing = groups[key] {
                if !existing.binds.contains(bind) { existing.binds.append(bind) }
                groups[key] = existing
            } else {
                groups[key] = (proc.command, [bind])
                keyOrder.append(key)
            }
        }
    }

    return keyOrder.map { key in
        let g = groups[key]!
        let sortedBinds = g.binds.sorted { $0.family.rawValue < $1.family.rawValue }
        return PortRecord(
            port: key.port,
            pid: key.pid,
            processName: g.processName,
            executablePath: nil,
            commandLine: nil,
            binds: sortedBinds
        )
    }
}

/// Parses the `n` field's `addr:port` value. Handles three forms:
///   `*:3000`, `127.0.0.1:5000`, `[::1]:8080`, `[fe80::1%en0]:1234`.
private func parseAddressPort(_ raw: String) -> (address: String, port: UInt16)? {
    // IPv6 bracketed form
    if raw.hasPrefix("[") {
        guard let close = raw.firstIndex(of: "]") else { return nil }
        let address = String(raw[raw.index(after: raw.startIndex)..<close])
        let after = raw.index(after: close)
        guard after < raw.endIndex, raw[after] == ":" else { return nil }
        let portStr = raw[raw.index(after: after)...]
        guard let port = UInt16(portStr) else { return nil }
        return (address, port)
    }
    // Plain "address:port"
    guard let lastColon = raw.lastIndex(of: ":") else { return nil }
    let address = String(raw[raw.startIndex..<lastColon])
    let portStr = raw[raw.index(after: lastColon)...]
    guard let port = UInt16(portStr) else { return nil }
    return (address, port)
}

/// lsof escapes non-printable bytes in command names as `\xHH`. Decode them back
/// to UTF-8 bytes when possible. Spaces and printable ASCII pass through.
private func decodeLsofEscapes(_ raw: String) -> String {
    guard raw.contains("\\x") else { return raw }
    var bytes: [UInt8] = []
    let scalars = Array(raw.unicodeScalars)
    var i = 0
    while i < scalars.count {
        if scalars[i] == "\\", i + 3 < scalars.count, scalars[i + 1] == "x",
           let hi = hexNibble(scalars[i + 2]), let lo = hexNibble(scalars[i + 3]) {
            bytes.append(UInt8(hi << 4 | lo))
            i += 4
        } else {
            // Append the scalar's UTF-8 bytes
            for byte in String(scalars[i]).utf8 { bytes.append(byte) }
            i += 1
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

private func hexNibble(_ s: Unicode.Scalar) -> UInt8? {
    switch s {
    case "0"..."9": return UInt8(s.value - Unicode.Scalar("0").value)
    case "a"..."f": return UInt8(s.value - Unicode.Scalar("a").value + 10)
    case "A"..."F": return UInt8(s.value - Unicode.Scalar("A").value + 10)
    default: return nil
    }
}

// MARK: - sysctl KERN_PROCARGS2 helper

/// Reads `KERN_PROCARGS2` for a pid and extracts the executable path and the
/// space-joined argv. Returns `(nil, nil)` on any failure (permission, race,
/// pid no longer alive). Silent by design — caller falls back to lsof's command.
func parseProcArgs(forPid pid: pid_t) -> (path: String?, command: String?) {
    var size: Int = 0
    var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    // First call: ask for size.
    if sysctl(&name, 3, nil, &size, nil, 0) != 0 || size == 0 {
        return (nil, nil)
    }
    var buffer = [UInt8](repeating: 0, count: size)
    if sysctl(&name, 3, &buffer, &size, nil, 0) != 0 {
        return (nil, nil)
    }

    // Layout: <argc:Int32><executable path NUL>[padding NULs]<argv[0] NUL><argv[1] NUL>...
    guard size >= MemoryLayout<Int32>.size else { return (nil, nil) }
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    if argc < 0 { return (nil, nil) }

    var cursor = MemoryLayout<Int32>.size
    // Read NUL-terminated executable path.
    let pathStart = cursor
    while cursor < buffer.count && buffer[cursor] != 0 { cursor += 1 }
    let pathBytes = buffer[pathStart..<cursor]
    let path = String(decoding: pathBytes, as: UTF8.self)
    // Skip padding NULs.
    while cursor < buffer.count && buffer[cursor] == 0 { cursor += 1 }

    // Read argc NUL-terminated argv entries.
    var argv: [String] = []
    var collected = 0
    while collected < Int(argc) && cursor < buffer.count {
        let start = cursor
        while cursor < buffer.count && buffer[cursor] != 0 { cursor += 1 }
        argv.append(String(decoding: buffer[start..<cursor], as: UTF8.self))
        if cursor < buffer.count { cursor += 1 } // skip NUL
        collected += 1
    }
    let command = argv.joined(separator: " ")
    return (path.isEmpty ? nil : path, command.isEmpty ? nil : command)
}
