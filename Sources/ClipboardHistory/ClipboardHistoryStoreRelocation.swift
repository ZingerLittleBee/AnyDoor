import Darwin
import Foundation
import GRDB
import os

private let logger = Logger(
    subsystem: "dev.bybee.AnyDoor",
    category: "clipboardHistory.store"
)

/// Moves a Clipboard History v2 store out of the pre-v2 `ClipboardHistory`
/// folder into its own root (`ClipboardHistoryV2`).
///
/// Releases 1.8.0 through 4.1.1 delete every file in `ClipboardHistory` that
/// no legacy row names, and their Clear History empties the folder (1.2.0
/// through 4.1.1). Releases 4.2.0 through 4.2.5 kept the encrypted store in
/// that folder, so running an older release destroyed it. This runs before any
/// database connection opens and never reads the Keychain.
///
/// Invariants:
/// - A store only ever moves as a whole directory through `renamex_np`, so
///   the SQLite main file, WAL and shared-memory file are never separated;
///   nothing is copied or re-encrypted.
/// - The move itself deletes nothing but empty directories (`rmdir`).
/// - Every step is resumable: `stagingRoot` exists exactly while a move is in
///   progress, and a rerun finishes it.
/// - Non-store children of the legacy folder (pre-v2 payloads awaiting the
///   legacy migration) always end up back in the legacy folder.
/// - A legacy store never replaces a store that already holds data: it is
///   displaced under `displacedRoot` instead, as a pending candidate the
///   module weighs once it has the key (see `adoptPendingDisplacements`).
struct ClipboardHistoryStoreRelocation: Sendable {
    enum Outcome: Equatable, Sendable {
        case nothingToRelocate
        case relocated
        case displacedLegacyStore(URL)
        /// Another process holds the legacy store open while the new root
        /// already holds a store; the legacy one is moved by the next open
        /// (a later launch or a retry).
        case postponedWhileLegacyStoreInUse(pid_t)
    }

    /// A displaced store keeps this suffix until it has been weighed against
    /// the current store, so a crash or a locked Keychain between
    /// displacement and that check only postpones it.
    static let pendingSuffix = ".pending"

    /// Every name a v2 store creates in its root (`prepareStoreDirectories`,
    /// `databaseURL(in:)`, and SQLite's own sidecars). Pre-v2 releases never
    /// used these names: their payloads are flat files named by UUID.
    static let storeArtifactNames: Set<String> = [
        "history.sqlite",
        "history.sqlite-wal",
        "history.sqlite-shm",
        "history.sqlite-journal",
        "payloads",
        "staging",
    ]

    private static let databaseFileNames = [
        "history.sqlite",
        "history.sqlite-wal",
        "history.sqlite-shm",
        "history.sqlite-journal",
    ]

    /// The names an empty store may consist of, the same rule the legacy
    /// migration uses before it replaces an empty initial store.
    private static let emptyStoreNames: Set<String> = [
        "history.sqlite",
        "history.sqlite-wal",
        "history.sqlite-shm",
        "payloads",
        "staging",
    ]

    let legacyRoot: URL
    let storeRoot: URL
    let faultInjector: ClipboardHistoryFaultInjector

    init(
        legacyRoot: URL,
        storeRoot: URL,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector()
    ) {
        self.legacyRoot = legacyRoot
        self.storeRoot = storeRoot
        self.faultInjector = faultInjector
    }

    static func stagingRoot(forStoreRoot storeRoot: URL) -> URL {
        storeRoot.deletingLastPathComponent().appendingPathComponent(
            "\(storeRoot.lastPathComponent).relocating",
            isDirectory: true
        )
    }

    static func displacedRoot(forStoreRoot storeRoot: URL) -> URL {
        storeRoot.deletingLastPathComponent().appendingPathComponent(
            "\(storeRoot.lastPathComponent).displaced",
            isDirectory: true
        )
    }

    var parent: URL { storeRoot.deletingLastPathComponent() }

    var stagingRoot: URL { Self.stagingRoot(forStoreRoot: storeRoot) }

    var displacedRoot: URL { Self.displacedRoot(forStoreRoot: storeRoot) }

    /// True while store data may still live outside `storeRoot`: a move is
    /// half done, or the legacy folder still holds v2 store names. Reset must
    /// not delete the key then, or that store becomes unreadable.
    var hasUnfinishedRelocation: Bool {
        if exists(stagingRoot) {
            return true
        }
        do {
            return try containsStoreArtifacts(legacyRoot)
        } catch {
            return true
        }
    }

    func run(now: Date) throws -> Outcome {
        guard
            legacyRoot.standardizedFileURL.path
                != storeRoot.standardizedFileURL.path
        else {
            throw ClipboardHistoryStorageError.fileOperationFailed(EINVAL)
        }
        // Renaming needs both roots on one volume; siblings guarantee it.
        guard
            legacyRoot.deletingLastPathComponent().standardizedFileURL.path
                == parent.standardizedFileURL.path
        else {
            throw ClipboardHistoryStorageError.fileOperationFailed(EXDEV)
        }
        var outcome = Outcome.nothingToRelocate
        // A second pass only finds work when a resumed move meets a store an
        // older v2 release recreated in the legacy folder meanwhile.
        for _ in 0..<2 {
            let pass = try runPass(now: now)
            switch pass {
            case .nothingToRelocate:
                return outcome
            case .postponedWhileLegacyStoreInUse:
                return outcome == .nothingToRelocate ? pass : outcome
            case .relocated, .displacedLegacyStore:
                outcome = pass
            }
        }
        return outcome
    }

    private func runPass(now: Date) throws -> Outcome {
        if !exists(stagingRoot) {
            guard try containsStoreArtifacts(legacyRoot) else {
                return .nothingToRelocate
            }
            // Renaming a database another process has open would split its
            // later connections, opened by path, from the moved files.
            if let pid = Self.processHoldingStoreOpen(in: legacyRoot) {
                guard hasStoreData(storeRoot) else {
                    logger.error(
                        "Clipboard History store is open in process \(pid, privacy: .public); not moving it"
                    )
                    throw ClipboardHistoryStorageError.fileOperationFailed(
                        EBUSY
                    )
                }
                logger.notice(
                    "Postponed moving a legacy Clipboard History store that process \(pid, privacy: .public) has open"
                )
                return .postponedWhileLegacyStoreInUse(pid)
            }
            // Detach the whole folder in one atomic rename.
            try rename(legacyRoot, to: stagingRoot)
            try syncDirectory(parent)
            try faultInjector.check(.storeRelocationAfterDetach)
        }

        // Hand every non-store child back to the legacy folder.
        guard let stagedNames = try Self.entryNames(in: stagingRoot) else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ENOENT)
        }
        let leftovers = stagedNames
            .filter { !Self.storeArtifactNames.contains($0) }
            .sorted()
        if !leftovers.isEmpty {
            try makeDirectory(legacyRoot)
            for name in leftovers {
                try moveKeepingBoth(
                    stagingRoot.appendingPathComponent(name),
                    into: legacyRoot,
                    as: name
                )
                try faultInjector.check(.storeRelocationAfterLeftoverReturned)
            }
            try syncDirectory(legacyRoot)
            try syncDirectory(stagingRoot)
        }

        // Publish atomically, or keep the existing store and move the legacy
        // one aside when both locations hold store data.
        if hasStoreData(storeRoot) {
            guard hasStoreData(stagingRoot) else {
                try removeEmptySkeleton(stagingRoot)
                try syncDirectory(parent)
                removeIfEmpty(legacyRoot)
                return .nothingToRelocate
            }
            try makeDirectory(displacedRoot)
            let name = Self.displacementName(at: now) + Self.pendingSuffix
            let destination = displacedRoot.appendingPathComponent(
                name,
                isDirectory: true
            )
            try rename(stagingRoot, to: destination)
            try syncDirectory(displacedRoot)
            try syncDirectory(parent)
            try faultInjector.check(.storeRelocationAfterDisplacement)
            logger.notice(
                "Kept a legacy Clipboard History store aside as \(name, privacy: .public)"
            )
            removeIfEmpty(legacyRoot)
            return .displacedLegacyStore(destination)
        }
        if exists(storeRoot) {
            // A root without store data: an empty skeleton is removed, and
            // anything unexpected is moved aside rather than deleted.
            do {
                try removeEmptySkeleton(storeRoot)
            } catch {
                try makeDirectory(displacedRoot)
                try rename(
                    storeRoot,
                    to: displacedRoot.appendingPathComponent(
                        "\(Self.displacementName(at: now))-target",
                        isDirectory: true
                    )
                )
                try syncDirectory(displacedRoot)
            }
        }
        try faultInjector.check(.storeRelocationBeforePublication)
        try rename(stagingRoot, to: storeRoot)
        try syncDirectory(parent)
        try faultInjector.check(.storeRelocationAfterPublication)
        logger.notice("Moved the Clipboard History store into its own folder")
        removeIfEmpty(legacyRoot)
        return .relocated
    }

    // MARK: - Displaced stores

    /// Displaced stores not yet weighed against the current store, oldest
    /// first (names start with a UTC timestamp).
    func pendingDisplacements() throws -> [URL] {
        guard let names = try Self.entryNames(in: displacedRoot) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(Self.pendingSuffix) }
            .sorted()
            .map { displacedRoot.appendingPathComponent($0, isDirectory: true) }
    }

    /// Exchanges the store root with `candidate` in one atomic
    /// `renamex_np(RENAME_SWAP)`, so after a crash both names point either at
    /// their old directories or at the new ones. The caller has closed every
    /// connection to both stores. Throws only when nothing moved.
    func exchange(withCandidate candidate: URL) throws {
        try faultInjector.check(.storeRelocationBeforeAdoption)
        try swap(storeRoot, candidate)
    }

    /// Makes a completed exchange durable. The previous store now sits at
    /// the candidate's pending name, to be weighed like any candidate.
    func completeExchange() throws {
        try syncDirectory(parent)
        try syncDirectory(displacedRoot)
        try faultInjector.check(.storeRelocationAfterAdoption)
    }

    /// Undoes an exchange whose adopted store did not open.
    func revertExchange(withCandidate candidate: URL) throws {
        try swap(storeRoot, candidate)
        try syncDirectory(parent)
        try syncDirectory(displacedRoot)
    }

    /// Drops the pending suffix: the store has been weighed and is kept aside
    /// until Reset removes it.
    func settle(_ candidate: URL) throws {
        let settledName = String(
            candidate.lastPathComponent.dropLast(Self.pendingSuffix.count)
        )
        try moveKeepingBoth(candidate, into: displacedRoot, as: settledName)
        try syncDirectory(displacedRoot)
    }

    /// Removes a displaced store the caller verified to be empty. Unlinks
    /// only the names an empty store consists of, main database file last,
    /// so a crash leaves either an openable empty store or a bare skeleton,
    /// both of which are weighed as empty again. Anything else in the folder
    /// makes the final `rmdir` fail and keeps the folder.
    func removeEmptyCandidate(_ candidate: URL) throws {
        for name in ["payloads", "staging"] {
            let child = candidate.appendingPathComponent(name)
            if rmdir(child.path) != 0, errno != ENOENT {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
        }
        for name in [
            "history.sqlite-shm", "history.sqlite-wal", "history.sqlite",
        ] {
            let child = candidate.appendingPathComponent(name)
            if unlink(child.path) != 0, errno != ENOENT {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
        }
        guard rmdir(candidate.path) == 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        try syncDirectory(displacedRoot)
    }

    // MARK: - Predicates

    /// SQLite's unix VFS holds a shared lock on the WAL-index "DMS" byte
    /// (offset 128 of the `-shm` file) for as long as a connection has the
    /// database open. `F_GETLK` reports another process's lock without taking
    /// one. Only valid while this process has no connection to that store: a
    /// process never sees its own locks as conflicts, and closing the probe
    /// descriptor drops this process's own POSIX locks on the file.
    static func processHoldingStoreOpen(in directory: URL) -> pid_t? {
        let sharedMemory = directory.appendingPathComponent(
            "history.sqlite-shm"
        )
        let descriptor = open(sharedMemory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 128
        lock.l_len = 1
        guard fcntl(descriptor, F_GETLK, &lock) == 0,
            lock.l_type != Int16(F_UNLCK)
        else {
            return nil
        }
        return lock.l_pid
    }

    /// Whether `directory` holds any v2 store name. A folder that exists but
    /// cannot be listed throws: it may hold a store.
    func containsStoreArtifacts(_ directory: URL) throws -> Bool {
        guard let names = try Self.entryNames(in: directory) else {
            return false
        }
        return names.contains { Self.storeArtifactNames.contains($0) }
    }

    /// A database file, or a non-empty payload or staging folder: the same
    /// meaning as `ClipboardHistoryModule.hasStoreArtifacts(at:)`. Anything
    /// that cannot be inspected counts as data, so an unreadable store is
    /// never published over or treated as empty.
    func hasStoreData(_ directory: URL) -> Bool {
        for name in Self.databaseFileNames {
            if exists(directory.appendingPathComponent(name)) {
                return true
            }
        }
        for name in ["payloads", "staging"] {
            do {
                if let children = try Self.entryNames(
                    in: directory.appendingPathComponent(name)
                ), !children.isEmpty {
                    return true
                }
            } catch {
                return true
            }
        }
        return false
    }

    /// Whether `directory` consists only of the files of an empty store (no
    /// payloads, nothing staged), the rule the legacy migration applies
    /// before it replaces an empty initial store. The entry count is the
    /// caller's to check.
    static func containsOnlyEmptyStoreFiles(_ directory: URL) -> Bool {
        do {
            guard let names = try entryNames(in: directory),
                names.allSatisfy(emptyStoreNames.contains)
            else {
                return false
            }
            for name in ["payloads", "staging"] where names.contains(name) {
                guard
                    let children = try entryNames(
                        in: directory.appendingPathComponent(name)
                    ),
                    children.isEmpty
                else {
                    return false
                }
            }
            return true
        } catch {
            return false
        }
    }

    func databaseFileExists(in directory: URL) -> Bool {
        exists(directory.appendingPathComponent("history.sqlite"))
    }

    /// `<UTC timestamp>-<8 hex digits>`, so names sort chronologically and
    /// never collide within a second.
    static func displacementName(at date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        // No separator options: the stamp reads like 20261001T050607Z.
        formatter.formatOptions = [
            .withYear, .withMonth, .withDay, .withTime, .withTimeZone,
        ]
        return "\(formatter.string(from: date))-\(randomSuffix())"
    }

    // MARK: - File operations

    private static func randomSuffix() -> String {
        UUID().uuidString.prefix(8).lowercased()
    }

    /// The names in `directory`, or nil when it does not exist or is not a
    /// directory.
    private static func entryNames(in directory: URL) throws -> [String]? {
        guard let stream = opendir(directory.path) else {
            let failure = errno
            if failure == ENOENT || failure == ENOTDIR {
                return nil
            }
            throw ClipboardHistoryStorageError.fileOperationFailed(failure)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 {
                    throw ClipboardHistoryStorageError.fileOperationFailed(
                        errno
                    )
                }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
    }

    /// Whether anything exists at `url`. A lookup that fails for any reason
    /// but absence counts as existing, so it is never overwritten.
    private func exists(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            return true
        }
        return errno != ENOENT && errno != ENOTDIR
    }

    private func rename(_ source: URL, to destination: URL) throws {
        guard
            renamex_np(source.path, destination.path, UInt32(RENAME_EXCL))
                == 0
        else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
    }

    private func swap(_ first: URL, _ second: URL) throws {
        guard
            renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0
        else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
    }

    /// Moves `child` into `directory` as `name`, or as
    /// `<name>.relocated-<8 hex digits>` when that name is taken.
    private func moveKeepingBoth(
        _ child: URL,
        into directory: URL,
        as name: String
    ) throws {
        let preferred = directory.appendingPathComponent(name)
        if renamex_np(child.path, preferred.path, UInt32(RENAME_EXCL)) == 0 {
            return
        }
        guard errno == EEXIST else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        try rename(
            child,
            to: directory.appendingPathComponent(
                "\(name).relocated-\(Self.randomSuffix())"
            )
        )
    }

    private func makeDirectory(_ directory: URL) throws {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
    }

    private func removeEmptySkeleton(_ directory: URL) throws {
        for name in ["payloads", "staging"] {
            let child = directory.appendingPathComponent(name)
            if rmdir(child.path) != 0, errno != ENOENT {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
        }
        guard rmdir(directory.path) == 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
    }

    private func removeIfEmpty(_ directory: URL) {
        _ = rmdir(directory.path)
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0
        else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
    }
}

extension ClipboardHistoryModule {
    /// Finishes any move of the store out of the pre-v2 folder, then opens
    /// the store, then weighs displaced stores against it.
    ///
    /// A failed move blocks only when the new root holds no store yet: the
    /// result is then `.storeRelocationFailed`, reached before any Keychain
    /// access, so the key is never created or deleted and nothing is created
    /// at the new root. When the new root already holds a store, the failure
    /// is logged and that store opens; the move is retried by the next open
    /// (a later launch or a retry).
    static func relocateAndResolveStore(
        relocation: ClipboardHistoryStoreRelocation?,
        at root: URL,
        keyStore: any ClipboardHistoryMasterKeyStoring,
        maintenanceDate: Date
    ) -> StoreResolution {
        guard let relocation else {
            return resolveStore(
                at: root,
                keyStore: keyStore,
                maintenanceDate: maintenanceDate
            )
        }
        do {
            _ = try relocation.run(now: maintenanceDate)
        } catch {
            guard relocation.hasStoreData(root) else {
                logger.error(
                    "Clipboard History store relocation failed: \(String(describing: error), privacy: .public)"
                )
                return unavailable(.storeRelocationFailed)
            }
            logger.error(
                "Clipboard History store relocation failed; opening the store already in place: \(String(describing: error), privacy: .public)"
            )
            return resolveStore(
                at: root,
                keyStore: keyStore,
                maintenanceDate: maintenanceDate
            )
        }
        let resolution = resolveStore(
            at: root,
            keyStore: keyStore,
            maintenanceDate: maintenanceDate
        )
        return adoptPendingDisplacements(
            relocation: relocation,
            resolution: resolution,
            root: root,
            maintenanceDate: maintenanceDate
        )
    }

    private enum DisplacedStoreWeight {
        /// Does not open with the current key, or cannot be inspected.
        case unreadable
        case empty
        case populated
    }

    /// Weighs each pending displaced store, newest first, with the keys the
    /// resolution already loaded (the Keychain item is never read twice).
    /// A store that does not open is kept aside and never adopted; an empty
    /// one is removed; a populated one replaces the current store only while
    /// the current store is empty, and is kept aside otherwise. While another
    /// process has either store open, it stays pending for the next open.
    private static func adoptPendingDisplacements(
        relocation: ClipboardHistoryStoreRelocation,
        resolution: StoreResolution,
        root: URL,
        maintenanceDate: Date
    ) -> StoreResolution {
        guard resolution.availability == .ready,
            let currentDatabase = resolution.database,
            let keys = resolution.keys
        else {
            // Weighing needs the key this open could not use; pending
            // stores wait for the next open.
            return resolution
        }
        let candidates: [URL]
        do {
            candidates = try relocation.pendingDisplacements()
        } catch {
            logger.error(
                "Could not list displaced Clipboard History stores: \(String(describing: error), privacy: .public)"
            )
            return resolution
        }
        guard !candidates.isEmpty else { return resolution }

        var current = resolution
        var currentIsEmpty = isEmptyStore(currentDatabase, at: root)
        for candidate in candidates.reversed() {
            switch weighDisplacedStore(
                at: candidate,
                keys: keys,
                relocation: relocation
            ) {
            case .unreadable:
                logger.notice(
                    "Kept a displaced Clipboard History store aside: it does not open with the current key"
                )
                settle(candidate, relocation: relocation)
            case .empty:
                removeEmptyCandidate(candidate, relocation: relocation)
            case .populated where !currentIsEmpty:
                settle(candidate, relocation: relocation)
            case .populated:
                guard let liveDatabase = current.database else {
                    return current
                }
                do {
                    try liveDatabase.close()
                } catch {
                    logger.error(
                        "Could not close the empty Clipboard History store to adopt a displaced one"
                    )
                    return current
                }
                // A process with either store open (another running copy of
                // AnyDoor) would keep writing to the files it opened after
                // the swap, while its payload store follows the folder names.
                // Checked only now: this process holds no connection to
                // either store, so its own locks cannot hide one.
                if let pid = [root, candidate].lazy.compactMap(
                    ClipboardHistoryStoreRelocation.processHoldingStoreOpen
                ).first {
                    logger.notice(
                        "Postponed adopting a displaced Clipboard History store while process \(pid, privacy: .public) has a store open"
                    )
                    return openStore(
                        at: root,
                        keys: keys,
                        maintenanceDate: maintenanceDate
                    )
                }
                current = adopt(
                    candidate,
                    keys: keys,
                    relocation: relocation,
                    root: root,
                    maintenanceDate: maintenanceDate
                )
                guard current.availability == .ready,
                    let adopted = current.database
                else {
                    return current
                }
                currentIsEmpty = isEmptyStore(adopted, at: root)
            }
        }
        return current
    }

    /// Swaps `candidate` in for the closed, empty current store. Every exit
    /// reopens whichever store `root` holds, with the same keys.
    private static func adopt(
        _ candidate: URL,
        keys: ClipboardHistoryDerivedKeys,
        relocation: ClipboardHistoryStoreRelocation,
        root: URL,
        maintenanceDate: Date
    ) -> StoreResolution {
        do {
            try relocation.exchange(withCandidate: candidate)
        } catch {
            logger.error(
                "Could not adopt a displaced Clipboard History store: \(String(describing: error), privacy: .public)"
            )
            return openStore(
                at: root,
                keys: keys,
                maintenanceDate: maintenanceDate
            )
        }
        let adopted: StoreResolution
        do {
            try relocation.completeExchange()
            adopted = openStore(
                at: root,
                keys: keys,
                maintenanceDate: maintenanceDate
            )
        } catch {
            logger.error(
                "Adopting a displaced Clipboard History store failed: \(String(describing: error), privacy: .public)"
            )
            adopted = unavailable(.storeIOFailure)
        }
        guard adopted.availability == .ready else {
            do {
                try relocation.revertExchange(withCandidate: candidate)
            } catch {
                logger.error(
                    "Could not undo adopting a displaced Clipboard History store: \(String(describing: error), privacy: .public)"
                )
            }
            return openStore(
                at: root,
                keys: keys,
                maintenanceDate: maintenanceDate
            )
        }
        logger.notice(
            "Adopted a displaced Clipboard History store in place of an empty one"
        )
        // The previous, empty store now holds the candidate's pending name.
        switch weighDisplacedStore(
            at: candidate,
            keys: keys,
            relocation: relocation
        ) {
        case .empty:
            removeEmptyCandidate(candidate, relocation: relocation)
        case .unreadable, .populated:
            settle(candidate, relocation: relocation)
        }
        return adopted
    }

    /// Opens a displaced store in place, never creating one: a candidate
    /// without a database file is empty only when nothing else is there.
    private static func weighDisplacedStore(
        at candidate: URL,
        keys: ClipboardHistoryDerivedKeys,
        relocation: ClipboardHistoryStoreRelocation
    ) -> DisplacedStoreWeight {
        guard relocation.databaseFileExists(in: candidate) else {
            return relocation.hasStoreData(candidate)
                || !ClipboardHistoryStoreRelocation
                    .containsOnlyEmptyStoreFiles(candidate)
                ? .unreadable
                : .empty
        }
        let database: DatabasePool
        do {
            database = try openDatabase(
                at: databaseURL(in: candidate),
                databaseKey: keys.databaseKey
            )
        } catch {
            return .unreadable
        }
        let isEmpty = isEmptyStore(database, at: candidate)
        do {
            try database.close()
        } catch {
            return .unreadable
        }
        return isEmpty ? .empty : .populated
    }

    /// No entries, no payloads and nothing staged. A store that cannot be
    /// counted is not empty.
    static func isEmptyStore(_ database: DatabasePool, at root: URL) -> Bool {
        let entryCount: Int
        do {
            entryCount = try database.read {
                try Int.fetchOne(
                    $0,
                    sql: "SELECT COUNT(*) FROM clipboard_entries"
                ) ?? 0
            }
        } catch {
            return false
        }
        return entryCount == 0
            && ClipboardHistoryStoreRelocation.containsOnlyEmptyStoreFiles(
                root
            )
    }

    private static func settle(
        _ candidate: URL,
        relocation: ClipboardHistoryStoreRelocation
    ) {
        do {
            try relocation.settle(candidate)
        } catch {
            logger.error(
                "Could not settle a displaced Clipboard History store: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private static func removeEmptyCandidate(
        _ candidate: URL,
        relocation: ClipboardHistoryStoreRelocation
    ) {
        do {
            try relocation.removeEmptyCandidate(candidate)
            logger.notice("Removed an empty displaced Clipboard History store")
        } catch {
            logger.error(
                "Could not remove an empty displaced Clipboard History store: \(String(describing: error), privacy: .public)"
            )
            settle(candidate, relocation: relocation)
        }
    }
}
