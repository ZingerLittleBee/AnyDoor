import CryptoKit
import Darwin
import Foundation

enum ClipboardHistoryPayloadKind: UInt8, Sendable {
    case bitmap = 1
    case thumbnail = 2
    case legacyOwnedFile = 3

    var databaseValue: String {
        switch self {
        case .bitmap:
            "bitmap"
        case .thumbnail:
            "thumbnail"
        case .legacyOwnedFile:
            "legacyOwnedFile"
        }
    }
}

enum ClipboardHistoryFaultPoint: Hashable, Sendable {
    case payloadWrite
    case payloadAuthentication
    case payloadDurability
    case payloadPublication
    case databaseTransaction
    case searchInsertAfterField
    case searchInsertAfterTrigram
    case searchInsertAfterShortGrams
    case searchDeleteAfterTrigram
    case searchDeleteAfterShortGrams
    case searchUpdateAfterOldTrigram
    case searchUpdateAfterOldShortGrams
    case searchUpdateAfterField
    case searchUpdateAfterNewTrigram
    case searchUpdateAfterNewShortGrams
    case searchRebuildBeforePublish
    case logicalDeletionAfterSearchIndexes
    case logicalDeletionAfterEntries
    case logicalDeletionAfterPayloadRows
    case payloadDeletion
    case orphanReconciliation
}

struct ClipboardHistoryFaultInjector: Sendable {
    let points: Set<ClipboardHistoryFaultPoint>

    init(points: Set<ClipboardHistoryFaultPoint> = []) {
        self.points = points
    }

    func check(_ point: ClipboardHistoryFaultPoint) throws {
        if points.contains(point) {
            throw ClipboardHistoryStorageError.injected(point)
        }
    }
}

enum ClipboardHistoryStorageError: Error, Equatable {
    case injected(ClipboardHistoryFaultPoint)
    case invalidPayloadEnvelope
    case payloadAuthenticationFailed
    case unsafePayloadPath
    case fileOperationFailed(Int32)
}

struct ClipboardHistoryPublishedPayload: Equatable, Sendable {
    let id: UUID
    let relativePath: String
    let kind: ClipboardHistoryPayloadKind
    let cryptoVersion: Int
    let plaintextByteCount: Int
}

struct ClipboardHistoryPayloadStore: Sendable {
    private static let magic = Data("ADCHPAYL".utf8)
    private static let cryptoVersion: UInt8 = 1

    let root: URL
    let key: Data
    let faultInjector: ClipboardHistoryFaultInjector

    private var payloadDirectory: URL {
        root.appendingPathComponent("payloads")
    }

    private var stagingDirectory: URL {
        root.appendingPathComponent("staging")
    }

    func publish(
        _ plaintext: Data,
        kind: ClipboardHistoryPayloadKind
    ) throws -> ClipboardHistoryPublishedPayload {
        let identifier = UUID()
        let relativePath = "\(identifier.uuidString.lowercased()).payload"
        let envelope = try encrypt(plaintext, kind: kind)
        let stagingName = "\(identifier.uuidString.lowercased()).staging"

        let stagingDirectoryFD = open(
            stagingDirectory.path,
            O_DIRECTORY | O_RDONLY
        )
        guard stagingDirectoryFD >= 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        defer { close(stagingDirectoryFD) }

        let payloadDirectoryFD = open(
            payloadDirectory.path,
            O_DIRECTORY | O_RDONLY
        )
        guard payloadDirectoryFD >= 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        defer { close(payloadDirectoryFD) }

        let fileFD = stagingName.withCString {
            openat(
                stagingDirectoryFD,
                $0,
                O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY,
                mode_t(0o600)
            )
        }
        guard fileFD >= 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }

        var published = false
        defer {
            close(fileFD)
            if !published {
                _ = stagingName.withCString {
                    unlinkat(stagingDirectoryFD, $0, 0)
                }
            }
        }

        try faultInjector.check(.payloadWrite)
        try writeAll(envelope, to: fileFD)
        try faultInjector.check(.payloadDurability)
        if fcntl(fileFD, F_FULLFSYNC) != 0, fsync(fileFD) != 0 {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        try faultInjector.check(.payloadPublication)

        let renameResult = stagingName.withCString { source in
            relativePath.withCString { destination in
                renameatx_np(
                    stagingDirectoryFD,
                    source,
                    payloadDirectoryFD,
                    destination,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameResult == 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        published = true
        if fsync(payloadDirectoryFD) != 0 {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }

        return ClipboardHistoryPublishedPayload(
            id: identifier,
            relativePath: relativePath,
            kind: kind,
            cryptoVersion: Int(Self.cryptoVersion),
            plaintextByteCount: plaintext.count
        )
    }

    func materialize(
        relativePath: String,
        expectedKind: ClipboardHistoryPayloadKind
    ) throws -> Data {
        guard Self.isSafePayloadName(relativePath) else {
            throw ClipboardHistoryStorageError.unsafePayloadPath
        }
        let url = payloadDirectory.appendingPathComponent(relativePath)
        let envelope = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try decrypt(envelope, expectedKind: expectedKind)
    }

    func delete(relativePath: String) throws {
        guard Self.isSafePayloadName(relativePath) else {
            throw ClipboardHistoryStorageError.unsafePayloadPath
        }
        try faultInjector.check(.payloadDeletion)
        let result = relativePath.withCString { name in
            let directoryFD = open(payloadDirectory.path, O_DIRECTORY | O_RDONLY)
            guard directoryFD >= 0 else { return Int32(-1) }
            defer { close(directoryFD) }
            let result = unlinkat(directoryFD, name, 0)
            if result == 0 {
                _ = fsync(directoryFD)
            }
            return result
        }
        guard result == 0 || errno == ENOENT else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
    }

    func reconcile(
        referencedPaths: Set<String>,
        olderThan cutoff: Date
    ) throws -> Int {
        var removedCount = 0
        removedCount += try reconcileDirectory(
            payloadDirectory,
            allowedExtension: "payload",
            referencedPaths: referencedPaths,
            cutoff: cutoff
        )
        removedCount += try reconcileDirectory(
            stagingDirectory,
            allowedExtension: "staging",
            referencedPaths: [],
            cutoff: cutoff
        )
        return removedCount
    }

    private func encrypt(
        _ plaintext: Data,
        kind: ClipboardHistoryPayloadKind
    ) throws -> Data {
        let header = Self.magic + Data([Self.cryptoVersion, kind.rawValue])
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            authenticating: header
        )
        var envelope = header
        envelope.append(contentsOf: sealed.nonce)
        envelope.append(sealed.ciphertext)
        envelope.append(sealed.tag)
        return envelope
    }

    private func decrypt(
        _ envelope: Data,
        expectedKind: ClipboardHistoryPayloadKind
    ) throws -> Data {
        let headerCount = Self.magic.count + 2
        let nonceCount = 12
        let tagCount = 16
        guard envelope.count >= headerCount + nonceCount + tagCount else {
            throw ClipboardHistoryStorageError.invalidPayloadEnvelope
        }

        let header = envelope.prefix(headerCount)
        guard header.prefix(Self.magic.count) == Self.magic,
            header[Self.magic.count] == Self.cryptoVersion,
            header[Self.magic.count + 1] == expectedKind.rawValue
        else {
            throw ClipboardHistoryStorageError.invalidPayloadEnvelope
        }

        let nonceRange = headerCount..<(headerCount + nonceCount)
        let tagStart = envelope.count - tagCount
        do {
            let nonce = try AES.GCM.Nonce(data: envelope[nonceRange])
            let sealed = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: envelope[(headerCount + nonceCount)..<tagStart],
                tag: envelope[tagStart...]
            )
            try faultInjector.check(.payloadAuthentication)
            return try AES.GCM.open(
                sealed,
                using: SymmetricKey(data: key),
                authenticating: header
            )
        } catch {
            throw ClipboardHistoryStorageError.payloadAuthenticationFailed
        }
    }

    private func reconcileDirectory(
        _ directory: URL,
        allowedExtension: String,
        referencedPaths: Set<String>,
        cutoff: Date
    ) throws -> Int {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var removedCount = 0
        for child in children {
            guard child.pathExtension == allowedExtension,
                !referencedPaths.contains(child.lastPathComponent)
            else {
                continue
            }
            let values = try child.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                values.isSymbolicLink != true,
                let modifiedAt = values.contentModificationDate,
                modifiedAt <= cutoff
            else {
                continue
            }
            try faultInjector.check(.orphanReconciliation)
            try FileManager.default.removeItem(at: child)
            removedCount += 1
        }
        return removedCount
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw ClipboardHistoryStorageError.fileOperationFailed(errno)
                }
                offset += count
            }
        }
    }

    private static func isSafePayloadName(_ name: String) -> Bool {
        !name.isEmpty && name == URL(fileURLWithPath: name).lastPathComponent
            && name.hasSuffix(".payload")
    }
}

struct ClipboardHistoryReclamationReport: Equatable, Sendable {
    var attemptedPayloadCount = 0
    var reclaimedPayloadCount = 0
    var failedPayloadCount = 0

    mutating func merge(_ other: Self) {
        attemptedPayloadCount += other.attemptedPayloadCount
        reclaimedPayloadCount += other.reclaimedPayloadCount
        failedPayloadCount += other.failedPayloadCount
    }
}

actor ClipboardHistoryPayloadReclaimer {
    private var pending: [UUID: Task<ClipboardHistoryReclamationReport, Never>] = [:]
    private var completed = ClipboardHistoryReclamationReport()

    func enqueue(
        paths: [String],
        in payloadStore: ClipboardHistoryPayloadStore
    ) {
        guard !paths.isEmpty else { return }
        let identifier = UUID()
        let task = Task.detached(priority: .utility) {
            var report = ClipboardHistoryReclamationReport()
            for path in paths {
                report.attemptedPayloadCount += 1
                do {
                    try payloadStore.delete(relativePath: path)
                    report.reclaimedPayloadCount += 1
                } catch {
                    report.failedPayloadCount += 1
                }
            }
            return report
        }
        pending[identifier] = task
        Task { @concurrent [weak self] in
            let report = await task.value
            await self?.finish(identifier, report: report)
        }
    }

    func drain() async -> ClipboardHistoryReclamationReport {
        while !pending.isEmpty {
            let snapshot = pending
            for (identifier, task) in snapshot {
                let report = await task.value
                finish(identifier, report: report)
            }
        }
        let report = completed
        completed = ClipboardHistoryReclamationReport()
        return report
    }

    private func finish(
        _ identifier: UUID,
        report: ClipboardHistoryReclamationReport
    ) {
        guard pending.removeValue(forKey: identifier) != nil else {
            return
        }
        completed.merge(report)
    }
}
