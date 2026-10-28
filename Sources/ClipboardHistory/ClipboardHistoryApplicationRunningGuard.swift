import AppKit
import Darwin
import Foundation

struct ClipboardApplicationFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let birthSeconds: Int
    let birthNanoseconds: Int

    init(_ url: URL, directory: Bool) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(directory ? S_IFDIR : S_IFREG) else {
            throw ClipboardHistoryApplicationUpdateError.identityUncertain
        }
        device = status.st_dev; inode = status.st_ino
        birthSeconds = status.st_birthtimespec.tv_sec; birthNanoseconds = status.st_birthtimespec.tv_nsec
    }
}

struct ClipboardApplicationWitness: Sendable {
    let url: URL
    let executableURL: URL
    let identity: ClipboardApplicationFileIdentity
    let executableIdentity: ClipboardApplicationFileIdentity
    let bundleIdentifier: String?

    init(_ url: URL) throws {
        let information = try ClipboardApplicationPackage.information(at: url)
        guard let name = information["CFBundleExecutable"] as? String,
              ClipboardSyncFileIO.validFilename(name) else { throw ClipboardHistoryApplicationUpdateError.identityUncertain }
        self.url = url.standardizedFileURL
        executableURL = url.appendingPathComponent("Contents/MacOS").appendingPathComponent(name).standardizedFileURL
        // Intermediate components must be real directories too; an external
        // executable link cannot establish this associated package's identity.
        _ = try ClipboardApplicationFileIdentity(url.appendingPathComponent("Contents"), directory: true)
        _ = try ClipboardApplicationFileIdentity(url.appendingPathComponent("Contents/MacOS"), directory: true)
        identity = try ClipboardApplicationFileIdentity(url, directory: true)
        executableIdentity = try ClipboardApplicationFileIdentity(executableURL, directory: false)
        bundleIdentifier = information["CFBundleIdentifier"] as? String
    }

    static func inspect(_ root: URL) throws -> [Self] {
        let packages = try ClipboardApplicationPackage.applicationURLs(in: root)
        guard !packages.isEmpty else { throw ClipboardHistoryApplicationUpdateError.identityUncertain }
        return try packages.map(Self.init)
    }

    func validate() throws {
        guard try ClipboardApplicationFileIdentity(url, directory: true) == identity,
              try ClipboardApplicationFileIdentity(executableURL, directory: false) == executableIdentity else {
            throw ClipboardHistoryApplicationUpdateError.identityUncertain
        }
    }
}

/// NSWorkspace is refreshed on the main run loop. Keep matched application
/// instances, not reusable PIDs, so a moved or unreadable running bundle does
/// not become permission to replace it. KVO also covers LSUIElement apps.
@MainActor
final class ClipboardApplicationRunningGuard {
    nonisolated let linkedIdentity: Data
    private var witnesses: [ClipboardApplicationWitness]
    private var matched: [NSRunningApplication] = []
    private var observation: NSKeyValueObservation?
    private var exchanged = false

    init(witnesses: [ClipboardApplicationWitness], linkedIdentity: Data) {
        self.linkedIdentity = linkedIdentity
        self.witnesses = witnesses
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.rememberRunningApplications() }
        }
        rememberRunningApplications()
    }

    func refreshWitnesses(_ witnesses: [ClipboardApplicationWitness]) {
        self.witnesses = witnesses
        rememberRunningApplications()
    }

    func state() -> ClipboardHistoryApplicationUpdateState {
        do { try assertStopped(); return .ready }
        catch ClipboardHistoryApplicationUpdateError.running { return .running }
        catch { return .identityUncertain }
    }

    private func relationship(_ application: NSRunningApplication) -> ClipboardHistoryApplicationUpdateState {
        let bundle = application.bundleURL?.standardizedFileURL
        let executable = application.executableURL?.standardizedFileURL
        let rootIdentity = bundle.flatMap { try? ClipboardApplicationFileIdentity($0, directory: true) }
        let executableIdentity = executable.flatMap { try? ClipboardApplicationFileIdentity($0, directory: false) }
        for witness in witnesses {
            if bundle == witness.url || executable == witness.executableURL || rootIdentity == witness.identity || executableIdentity == witness.executableIdentity {
                return .running
            }
            if let identifier = witness.bundleIdentifier, application.bundleIdentifier == identifier,
               rootIdentity == nil && executableIdentity == nil { return .identityUncertain }
        }
        // Without either native location, an instance cannot be proven unrelated.
        return bundle == nil && executable == nil ? .identityUncertain : .ready
    }

    private func rememberRunningApplications() {
        matched.removeAll { $0.isTerminated }
        for application in NSWorkspace.shared.runningApplications where !application.isTerminated {
            if relationship(application) == .running, !matched.contains(where: { $0.isEqual(application) }) { matched.append(application) }
        }
    }

    func assertStopped(validateIdentity: Bool = true) throws {
        rememberRunningApplications()
        guard matched.isEmpty else { throw ClipboardHistoryApplicationUpdateError.running }
        if validateIdentity { for witness in witnesses { try witness.validate() } }
        for application in NSWorkspace.shared.runningApplications where !application.isTerminated {
            switch relationship(application) {
            case .running: throw ClipboardHistoryApplicationUpdateError.running
            case .identityUncertain: throw ClipboardHistoryApplicationUpdateError.identityUncertain
            default: break
            }
        }
    }

    /// Called after all long tree verification, immediately around the existing
    /// serialized authority gate and short exchange. This is not a system-wide
    /// process-launch lock; it refuses every running instance observable here.
    nonisolated func perform(_ mutation: @Sendable () throws -> Bool) throws -> Bool {
        try DispatchQueue.main.sync {
            try MainActor.assumeIsolated {
                // The second call can only be the existing journal's rollback.
                // The original package then lives at the displaced root, while
                // running-instance checks still protect the visible destination.
                try assertStopped(validateIdentity: !exchanged)
                let changed = try mutation()
                if changed { exchanged.toggle() }
                return changed
            }
        }
    }
}
