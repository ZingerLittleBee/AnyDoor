import Foundation
import GRDB
import Vision

enum ClipboardHistoryDerivedJobKind: String, CaseIterable, Sendable {
    case ocr
    case qr
}

protocol ClipboardHistoryVisionRecognizing: Sendable {
    func recognize(
        _ kind: ClipboardHistoryDerivedJobKind,
        in bitmaps: [Data]
    ) async throws -> [String]
}

struct ClipboardHistoryVisionRecognizer: ClipboardHistoryVisionRecognizing {
    @concurrent
    func recognize(
        _ kind: ClipboardHistoryDerivedJobKind,
        in bitmaps: [Data]
    ) async throws -> [String] {
        var values: [String] = []
        for bitmap in bitmaps {
            try Task.checkCancellation()
            switch kind {
            case .ocr:
                values.append(contentsOf: try recognizeText(in: bitmap))
            case .qr:
                values.append(contentsOf: try recognizeQRCodes(in: bitmap))
            }
        }
        try Task.checkCancellation()
        return values
    }

    private func recognizeText(in bitmap: Data) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(data: bitmap, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first?.string
        }.filter { !$0.isEmpty }
    }

    private func recognizeQRCodes(in bitmap: Data) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(data: bitmap, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }
}

struct ClipboardHistoryDerivedJobKey: Equatable, Sendable {
    let entryID: String
    let kind: ClipboardHistoryDerivedJobKind
    let eligibleGeneration: Int
}

final class ClipboardHistoryDerivedJobBootstrap: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancelAndWait() async {
        let task = takeTask()
        task?.cancel()
        await task?.value
    }

    private func takeTask() -> Task<Void, Never>? {
        lock.lock()
        let task = task
        self.task = nil
        lock.unlock()
        return task
    }
}

extension ClipboardHistoryModule {
    private struct DerivedJobClaim: Sendable {
        let key: ClipboardHistoryDerivedJobKey
        let attemptCount: Int
        let payloadPaths: [String]
    }

    public func setAutomaticImageTextIndexingEnabled(
        _ enabled: Bool
    ) throws {
        let database = try requiredDatabase()
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO clipboard_maintenance_metadata(
                        key, integer_value
                    ) VALUES ('automaticImageTextIndexingEnabled', ?)
                    ON CONFLICT(key) DO UPDATE SET
                        integer_value = excluded.integer_value,
                        real_value = NULL,
                        text_value = NULL,
                        data_value = NULL
                    """,
                arguments: [enabled]
            )
        }
        automaticImageTextIndexingEnabled = enabled
    }

    public func isAutomaticImageTextIndexingEnabled() throws -> Bool {
        let database = try requiredDatabase()
        return try database.read {
            try Self.automaticImageTextIndexingSetting(in: $0)
        }
    }

    static func storedAutomaticImageTextIndexingSetting(
        in database: DatabasePool?
    ) -> Bool {
        guard let database else { return false }
        return (try? database.read {
            try automaticImageTextIndexingSetting(in: $0)
        }) ?? false
    }

    private static func automaticImageTextIndexingSetting(
        in database: Database
    ) throws -> Bool {
        try Bool.fetchOne(
            database,
            sql: """
                SELECT integer_value
                FROM clipboard_maintenance_metadata
                WHERE key = 'automaticImageTextIndexingEnabled'
                """
        ) ?? false
    }

    func startDerivedJobSchedulerIfNeeded() {
        guard !Task.isCancelled,
            !isClosingStore,
            derivedJobSchedulerTask == nil,
            availability == .ready
        else {
            return
        }
        let token = UUID()
        derivedJobSchedulerToken = token
        derivedJobSchedulerTask = Task { [weak self] in
            await self?.runDerivedJobScheduler(token: token)
        }
    }

    func stopDerivedJobScheduler() async {
        await derivedJobBootstrap.cancelAndWait()
        let task = derivedJobSchedulerTask
        derivedJobSchedulerTask = nil
        derivedJobSchedulerToken = nil
        task?.cancel()
        await task?.value
        activeDerivedJob = nil
    }

    func cancelDerivedJobs(for entryIDs: Set<String>) {
        guard let activeDerivedJob,
            entryIDs.contains(activeDerivedJob.entryID)
        else {
            return
        }
        derivedJobSchedulerToken = nil
        let task = derivedJobSchedulerTask
        derivedJobSchedulerTask = nil
        self.activeDerivedJob = nil
        task?.cancel()
        startDerivedJobSchedulerIfNeeded()
    }

    func awaitDerivedJobsForTesting() async {
        startDerivedJobSchedulerIfNeeded()
        while let task = derivedJobSchedulerTask {
            await task.value
        }
    }

    private func runDerivedJobScheduler(token: UUID) async {
        do {
            try recoverInterruptedDerivedJobs()
        } catch {
            finishDerivedJobScheduler(token: token)
            return
        }

        while !Task.isCancelled {
            let claim: DerivedJobClaim
            do {
                guard let next = try claimNextDerivedJob() else {
                    break
                }
                claim = next
                activeDerivedJob = claim.key
            } catch {
                break
            }

            do {
                let bitmaps = try materializeBitmaps(for: claim)
                let values = try await visionRecognizer.recognize(
                    claim.key.kind,
                    in: bitmaps
                )
                try Task.checkCancellation()
                try publishDerivedValues(values, for: claim)
            } catch is CancellationError {
                try? restoreCancelledDerivedJob(claim)
                activeDerivedJob = nil
                break
            } catch {
                do {
                    try recordDerivedJobFailure(claim)
                } catch {
                    activeDerivedJob = nil
                    break
                }
            }
            activeDerivedJob = nil
        }
        finishDerivedJobScheduler(token: token)
    }

    private func finishDerivedJobScheduler(token: UUID) {
        guard derivedJobSchedulerToken == token else { return }
        derivedJobSchedulerToken = nil
        derivedJobSchedulerTask = nil
        activeDerivedJob = nil
    }

    private func recoverInterruptedDerivedJobs() throws {
        let database = try requiredDatabase()
        try database.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_derived_jobs
                    SET state = CASE
                            WHEN attempt_count >= 3 THEN 'failed'
                            ELSE 'pending'
                        END,
                        next_attempt_at = CASE
                            WHEN attempt_count >= 3 THEN NULL
                            ELSE ?
                        END
                    WHERE state = 'running'
                    """,
                arguments: [now().timeIntervalSince1970]
            )
        }
    }

    private func claimNextDerivedJob() throws -> DerivedJobClaim? {
        let database = try requiredDatabase()
        let timestamp = now().timeIntervalSince1970
        return try database.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT entry_id, kind, eligible_generation,
                           attempt_count
                    FROM clipboard_derived_jobs
                    WHERE state = 'pending'
                      AND attempt_count < 3
                      AND (
                          next_attempt_at IS NULL
                          OR next_attempt_at <= ?
                      )
                    ORDER BY COALESCE(next_attempt_at, 0),
                             entry_id, kind
                    LIMIT 1
                    """,
                arguments: [timestamp]
            ), let kind = ClipboardHistoryDerivedJobKind(
                rawValue: row["kind"]
            ) else {
                return nil
            }
            let entryID: String = row["entry_id"]
            let eligibleGeneration: Int = row["eligible_generation"]
            let previousAttemptCount: Int = row["attempt_count"]
            let attemptCount = previousAttemptCount + 1
            try database.execute(
                sql: """
                    UPDATE clipboard_derived_jobs
                    SET state = 'running', attempt_count = ?,
                        next_attempt_at = NULL
                    WHERE entry_id = ? AND kind = ?
                      AND eligible_generation = ?
                      AND state = 'pending'
                      AND attempt_count = ?
                    """,
                arguments: [
                    attemptCount,
                    entryID,
                    kind.rawValue,
                    eligibleGeneration,
                    previousAttemptCount,
                ]
            )
            guard database.changesCount == 1 else { return nil }
            let payloadPaths = try String.fetchAll(
                database,
                sql: """
                    SELECT payload.relative_path
                    FROM clipboard_representations AS representation
                    JOIN clipboard_payloads AS payload
                      ON payload.id = representation.payload_id
                    WHERE representation.entry_id = ?
                      AND representation.kind = 'bitmap'
                      AND payload.kind = 'bitmap'
                    ORDER BY representation.item_index,
                             representation.representation_index
                    """,
                arguments: [entryID]
            )
            return DerivedJobClaim(
                key: ClipboardHistoryDerivedJobKey(
                    entryID: entryID,
                    kind: kind,
                    eligibleGeneration: eligibleGeneration
                ),
                attemptCount: attemptCount,
                payloadPaths: payloadPaths
            )
        }
    }

    private func materializeBitmaps(
        for claim: DerivedJobClaim
    ) throws -> [Data] {
        guard !claim.payloadPaths.isEmpty,
            let entryUUID = UUID(uuidString: claim.key.entryID)
        else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        let payloadStore = try requiredPayloadStore()
        do {
            return try claim.payloadPaths.map {
                try payloadStore.materialize(
                    relativePath: $0,
                    expectedKind: .bitmap
                )
            }
        } catch {
            throw ClipboardHistoryModuleError.payloadUnavailable(
                ClipboardHistoryEntryID(entryUUID)
            )
        }
    }

    private func publishDerivedValues(
        _ values: [String],
        for claim: DerivedJobClaim
    ) throws {
        let database = try requiredDatabase()
        try database.write { database in
            guard try derivedJobMatches(
                claim,
                state: "running",
                in: database
            ) else {
                return
            }
            try Self.deleteSearchFields(
                forEntryID: claim.key.entryID,
                kind: claim.key.kind.rawValue,
                from: database,
                faultInjector: faultInjector
            )
            for (index, value) in values.enumerated() {
                try Self.insertSearchField(
                    value: value,
                    kind: claim.key.kind.rawValue,
                    index: index,
                    rankingGroup: Self.searchRankingGroup(
                        for: claim.key.kind.rawValue
                    ),
                    entryID: claim.key.entryID,
                    into: database,
                    faultInjector: faultInjector
                )
            }
            if claim.key.kind == .qr {
                try database.execute(
                    sql: """
                        DELETE FROM clipboard_entry_facets
                        WHERE entry_id = ? AND facet = ?
                        """,
                    arguments: [
                        claim.key.entryID,
                        ClipboardHistoryFacet.qrCode.rawValue,
                    ]
                )
                if !values.isEmpty {
                    try database.execute(
                        sql: """
                            INSERT INTO clipboard_entry_facets(entry_id, facet)
                            VALUES (?, ?)
                            """,
                        arguments: [
                            claim.key.entryID,
                            ClipboardHistoryFacet.qrCode.rawValue,
                        ]
                    )
                }
            }
            try database.execute(
                sql: """
                    UPDATE clipboard_derived_jobs
                    SET state = 'succeeded', next_attempt_at = NULL
                    WHERE entry_id = ? AND kind = ?
                      AND eligible_generation = ?
                      AND state = 'running'
                      AND attempt_count = ?
                    """,
                arguments: [
                    claim.key.entryID,
                    claim.key.kind.rawValue,
                    claim.key.eligibleGeneration,
                    claim.attemptCount,
                ]
            )
            guard database.changesCount == 1 else {
                throw ClipboardHistoryModuleError.storageFailure
            }
            try Self.bumpSearchIndexGeneration(in: database)
            try Self.bumpHistoryRevision(in: database)
            try faultInjector.check(.databaseTransaction)
        }
    }

    private func recordDerivedJobFailure(
        _ claim: DerivedJobClaim
    ) throws {
        let database = try requiredDatabase()
        try database.write { database in
            guard try derivedJobMatches(
                claim,
                state: "running",
                in: database
            ) else {
                return
            }
            let isExhausted = claim.attemptCount >= 3
            try database.execute(
                sql: """
                    UPDATE clipboard_derived_jobs
                    SET state = ?,
                        next_attempt_at = ?
                    WHERE entry_id = ? AND kind = ?
                      AND eligible_generation = ?
                      AND state = 'running'
                      AND attempt_count = ?
                    """,
                arguments: [
                    isExhausted ? "failed" : "pending",
                    isExhausted ? nil : now().timeIntervalSince1970,
                    claim.key.entryID,
                    claim.key.kind.rawValue,
                    claim.key.eligibleGeneration,
                    claim.attemptCount,
                ]
            )
        }
    }

    private func restoreCancelledDerivedJob(
        _ claim: DerivedJobClaim
    ) throws {
        let database = try requiredDatabase()
        try database.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_derived_jobs
                    SET state = 'pending',
                        attempt_count = MAX(attempt_count - 1, 0),
                        next_attempt_at = NULL
                    WHERE entry_id = ? AND kind = ?
                      AND eligible_generation = ?
                      AND state = 'running'
                      AND attempt_count = ?
                    """,
                arguments: [
                    claim.key.entryID,
                    claim.key.kind.rawValue,
                    claim.key.eligibleGeneration,
                    claim.attemptCount,
                ]
            )
        }
    }

    private func derivedJobMatches(
        _ claim: DerivedJobClaim,
        state: String,
        in database: Database
    ) throws -> Bool {
        try Int.fetchOne(
            database,
            sql: """
                SELECT 1
                FROM clipboard_derived_jobs
                WHERE entry_id = ? AND kind = ?
                  AND eligible_generation = ?
                  AND state = ?
                  AND attempt_count = ?
                """,
            arguments: [
                claim.key.entryID,
                claim.key.kind.rawValue,
                claim.key.eligibleGeneration,
                state,
                claim.attemptCount,
            ]
        ) == 1
    }
}
