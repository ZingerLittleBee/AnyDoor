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
}
