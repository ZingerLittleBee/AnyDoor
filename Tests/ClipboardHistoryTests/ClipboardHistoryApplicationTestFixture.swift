import AppKit
import CryptoKit
import Darwin
import Foundation

/// A test-owned application package. Construction is the only operation that
/// signs code; verification and snapshots never repair a received package.
struct ClipboardApplicationTestFixture: Sendable {
    let url: URL
    var executableURL: URL { url.appendingPathComponent("Contents/MacOS/FixtureApplication") }

    static func create(at url: URL, bundleIdentifier: String, resource: String,
        signed: Bool = true) throws -> Self {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        let sources = url.deletingLastPathComponent().appendingPathComponent("fixture-sources-\(UUID())")
        try manager.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: sources) }
        for directory in ["Contents/MacOS", "Contents/Helpers", "Contents/Resources"] {
            try manager.createDirectory(at: url.appendingPathComponent(directory), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755])
        }
        let info: [String: Any] = ["CFBundleIdentifier": bundleIdentifier, "CFBundleExecutable": "FixtureApplication",
            "CFBundlePackageType": "APPL", "CFBundleName": "Clipboard Test Fixture", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0", "LSUIElement": true, "NSHighResolutionCapable": true]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(resource.utf8).write(to: url.appendingPathComponent("Contents/Resources/Resource.txt"))
        try manager.createSymbolicLink(atPath: url.appendingPathComponent("Contents/Resources/ResourceLink.txt").path,
            withDestinationPath: "Resource.txt")
        let source = sources.appendingPathComponent("FixtureApplication.m")
        try Data(applicationSource.utf8).write(to: source)
        let helperSource = sources.appendingPathComponent("FixtureHelper.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: helperSource)
        let fixture = Self(url: url)
        let helper = url.appendingPathComponent("Contents/Helpers/FixtureHelper")
        try run("/usr/bin/xcrun", ["clang", "-fobjc-arc", "-framework", "AppKit", source.path, "-o", fixture.executableURL.path])
        try run("/usr/bin/xcrun", ["clang", helperSource.path, "-o", helper.path])
        for executable in [fixture.executableURL, helper] {
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        if signed {
            // Sign nested code first. --deep is verification-only, never signing.
            for target in [helper, url] {
                try run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", target.path])
            }
        }
        return fixture
    }

    @MainActor
    func launch() async throws -> ClipboardApplicationTestProcess {
        // Keep process channels outside any synchronized parent directory too.
        let control = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-process-\(UUID())")
        let manager = FileManager.default
        try manager.createDirectory(at: control, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let home = control.appendingPathComponent("Home")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [control.appendingPathComponent("ready").path, control.appendingPathComponent("stop").path]
        process.currentDirectoryURL = control
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["TMPDIR"] = control.path + "/"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            try? manager.removeItem(at: control)
            throw error
        }
        let owned = ClipboardApplicationTestProcess(process: process, controlDirectory: control)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard owned.isRunning else { throw ClipboardApplicationTestError.nativeVisibilityUnavailable }
                let ready = try? String(contentsOf: control.appendingPathComponent("ready"), encoding: .utf8)
                if ready == String(owned.processIdentifier),
                   let direct = NSRunningApplication(processIdentifier: owned.processIdentifier),
                   let workspace = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == owned.processIdentifier }),
                   [direct, workspace].allSatisfy({ application in
                       !application.isTerminated
                           && application.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
                           && application.executableURL?.resolvingSymlinksInPath() == executableURL.resolvingSymlinksInPath()
                   }) {
                    owned.runningApplication = direct
                    return owned
                }
                await ClipboardApplicationTestProcess.yieldMainLoop()
            }
            throw ClipboardApplicationTestError.nativeVisibilityUnavailable
        } catch {
            try? await owned.stop()
            throw error
        }
    }

    func verifySignature() throws {
        try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", url.path])
    }

    func contentsSnapshot() throws -> [String: ClipboardApplicationTestEntry] {
        var entries: [String: ClipboardApplicationTestEntry] = [".": try Self.entry(at: url)]
        func visit(_ directory: URL, relative: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
                let child = directory.appendingPathComponent(name)
                let path = relative.isEmpty ? name : relative + "/" + name
                let entry = try Self.entry(at: child)
                entries[path] = entry
                if entry.kind == .directory { try visit(child, relative: path) }
            }
        }
        try visit(url, relative: "")
        return entries
    }

    private static func entry(at url: URL) throws -> ClipboardApplicationTestEntry {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw POSIXError(.EIO) }
        let mode = UInt16(status.st_mode & 0o7777)
        switch status.st_mode & S_IFMT {
        case S_IFDIR: return .init(kind: .directory, digest: nil, mode: mode, linkTarget: nil)
        case S_IFLNK: return .init(kind: .symbolicLink, digest: nil, mode: mode,
            linkTarget: try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        case S_IFREG:
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            return .init(kind: .file, digest: digest, mode: mode, linkTarget: nil)
        default: throw CocoaError(.fileReadUnsupportedScheme)
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClipboardApplicationTestError.commandFailed(executable, process.terminationStatus, String(decoding: bytes, as: UTF8.self))
        }
    }

    private static let applicationSource = #"""
    #import <AppKit/AppKit.h>
    int main(int argc, const char *argv[]) {
        @autoreleasepool {
            if (argc != 3) return 2;
            NSString *ready = [NSString stringWithUTF8String:argv[1]];
            NSString *stop = [NSString stringWithUTF8String:argv[2]];
            NSApplication *app = [NSApplication sharedApplication];
            [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:90];
            [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *timer) {
                if (![[NSFileManager defaultManager] fileExistsAtPath:ready]) {
                    [[NSString stringWithFormat:@"%d", getpid()] writeToFile:ready atomically:YES
                        encoding:NSUTF8StringEncoding error:NULL];
                }
                if ([[NSFileManager defaultManager] fileExistsAtPath:stop] || [deadline timeIntervalSinceNow] <= 0) {
                    [timer invalidate];
                    [app terminate:nil];
                }
            }];
            [app run];
        }
        return 0;
    }
    """#
}

struct ClipboardApplicationTestEntry: Equatable, Sendable {
    enum Kind: Sendable { case directory, file, symbolicLink }
    let kind: Kind
    let digest: String?
    let mode: UInt16
    let linkTarget: String?
}

enum ClipboardApplicationTestError: Error {
    case commandFailed(String, Int32, String)
    case nativeVisibilityUnavailable
    case failedToExitNormally(Int32?)
}

/// Owns only the exact process created for this fixture, never a name or bundle
/// identifier match. Consumers register stop() in async teardown immediately.
@MainActor
final class ClipboardApplicationTestProcess {
    private let process: Process
    private let controlDirectory: URL
    fileprivate(set) var runningApplication: NSRunningApplication?
    var processIdentifier: pid_t { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var terminationStatus: Int32? { process.isRunning ? nil : process.terminationStatus }

    fileprivate init(process: Process, controlDirectory: URL) {
        self.process = process
        self.controlDirectory = controlDirectory
    }

    func stop() async throws {
        var forced = false
        if process.isRunning {
            // Cleanup must complete even when the calling test is cancelled.
            try? Data("stop".utf8).write(to: controlDirectory.appendingPathComponent("stop"), options: .atomic)
            await waitForExit(seconds: 5)
        }
        if process.isRunning {
            forced = true
            process.terminate()
            await waitForExit(seconds: 2)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            await waitForExit(seconds: 2)
        }
        guard !process.isRunning else { throw ClipboardApplicationTestError.failedToExitNormally(nil) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while runningApplication?.isTerminated == false, ContinuousClock.now < deadline {
            await Self.yieldMainLoop()
        }
        try? FileManager.default.removeItem(at: controlDirectory)
        guard !forced, process.terminationReason == .exit, process.terminationStatus == 0,
              runningApplication?.isTerminated != false else {
            throw ClipboardApplicationTestError.failedToExitNormally(process.terminationStatus)
        }
    }

    private func waitForExit(seconds: Int) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while process.isRunning, ContinuousClock.now < deadline { await Self.yieldMainLoop() }
    }

    /// Yield instead of blocking AppKit's main RunLoop. A cancelled test still
    /// allows its owned process's orderly shutdown and bounded fallback cleanup.
    fileprivate static func yieldMainLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
        }
    }
}
