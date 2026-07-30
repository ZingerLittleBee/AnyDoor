import Foundation
import GRDB

final class ClipboardHistoryMaintenanceBootstrap: @unchecked Sendable {
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

protocol ClipboardHistoryMaintenanceScheduling: Sendable {
    func sleep(until deadline: Date) async throws
}

struct SystemClipboardHistoryMaintenanceScheduler:
    ClipboardHistoryMaintenanceScheduling
{
    func sleep(until deadline: Date) async throws {
        let interval = max(deadline.timeIntervalSinceNow, 0)
        try await Task.sleep(
            nanoseconds: UInt64(
                min(interval, Double(UInt64.max) / 1_000_000_000)
                    * 1_000_000_000
            )
        )
    }
}

extension ClipboardHistoryModule {
    struct MaintenanceScheduleSnapshot: Sendable {
        let lastSuccess: Double?
        let nextDeadline: Double?
    }

    static let maintenanceInterval: TimeInterval = 24 * 60 * 60
    static let initialMaintenanceRetryDelay: TimeInterval = 5 * 60
    static let maximumMaintenanceRetryDelay: TimeInterval = 60 * 60

    func startMaintenanceTaskIfNeeded() {
        guard !Task.isCancelled,
            maintenanceTask == nil,
            availability == .ready,
            let maintenanceScheduler
        else {
            return
        }
        maintenanceTask = Task { [weak self] in
            await self?.runMaintenanceLoop(using: maintenanceScheduler)
        }
    }

    func stopMaintenanceTask() async {
        await maintenanceBootstrap.cancelAndWait()
        let task = maintenanceTask
        maintenanceTask = nil
        task?.cancel()
        await task?.value
    }

    func runMaintenanceLoop(
        using scheduler: any ClipboardHistoryMaintenanceScheduling
    ) async {
        var failureCount = 0
        var retryAt: Date?
        while !Task.isCancelled {
            let deadline: Date
            do {
                deadline = try maintenanceDeadline()
            } catch {
                failureCount += 1
                let target = now().addingTimeInterval(
                    Self.maintenanceRetryDelay(after: failureCount)
                )
                do {
                    try await scheduler.sleep(until: target)
                } catch {
                    return
                }
                continue
            }

            let target: Date
            if deadline <= now(), let retryAt {
                target = retryAt
            } else {
                target = deadline
            }
            do {
                try await scheduler.sleep(until: target)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            do {
                let currentDeadline = try maintenanceDeadline()
                guard currentDeadline <= now() else {
                    failureCount = 0
                    retryAt = nil
                    continue
                }
                _ = try performMaintenance()
                failureCount = 0
                retryAt = nil
            } catch {
                failureCount += 1
                retryAt = now().addingTimeInterval(
                    Self.maintenanceRetryDelay(after: failureCount)
                )
            }
        }
    }

    private func maintenanceDeadline() throws -> Date {
        let database = try requiredDatabase()
        let date = now()
        return try database.write { database in
            try Self.ensureMaintenanceDeadline(in: database, at: date)
        }
    }

    static func ensureMaintenanceDeadline(
        in database: Database,
        at date: Date
    ) throws -> Date {
        if let timestamp = try Double.fetchOne(
            database,
            sql: """
                SELECT real_value
                FROM clipboard_maintenance_metadata
                WHERE key = 'nextMaintenanceDeadline'
                """
        ) {
            return Date(timeIntervalSince1970: timestamp)
        }

        let lastSuccess = try Double.fetchOne(
            database,
            sql: """
                SELECT real_value
                FROM clipboard_maintenance_metadata
                WHERE key IN (
                    'lastMaintenanceSucceededAt',
                    'lastMaintenanceAt'
                )
                ORDER BY CASE key
                    WHEN 'lastMaintenanceSucceededAt' THEN 0
                    ELSE 1
                END
                LIMIT 1
                """
        )
        if let lastSuccess {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_maintenance_metadata(
                        key, real_value
                    ) VALUES ('lastMaintenanceSucceededAt', ?)
                    ON CONFLICT(key) DO UPDATE SET
                        integer_value = NULL,
                        real_value = excluded.real_value,
                        text_value = NULL,
                        data_value = NULL
                    """,
                arguments: [lastSuccess]
            )
        }
        let deadline = (lastSuccess.map {
            Date(timeIntervalSince1970: $0)
        } ?? date).addingTimeInterval(maintenanceInterval)
        try database.execute(
            sql: """
                INSERT INTO clipboard_maintenance_metadata(
                    key, real_value
                ) VALUES ('nextMaintenanceDeadline', ?)
                ON CONFLICT(key) DO NOTHING
                """,
            arguments: [deadline.timeIntervalSince1970]
        )
        return deadline
    }

    static func recordMaintenanceSuccess(
        in database: Database,
        at date: Date
    ) throws {
        for (key, value) in [
            ("lastMaintenanceSucceededAt", date.timeIntervalSince1970),
            (
                "nextMaintenanceDeadline",
                date.addingTimeInterval(maintenanceInterval)
                    .timeIntervalSince1970
            ),
        ] {
            try database.execute(
                sql: """
                    INSERT INTO clipboard_maintenance_metadata(
                        key, real_value
                    ) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        integer_value = NULL,
                        real_value = excluded.real_value,
                        text_value = NULL,
                        data_value = NULL
                    """,
                arguments: [key, value]
            )
        }
    }

    static func maintenanceScheduleSnapshot(
        in database: Database
    ) throws -> MaintenanceScheduleSnapshot {
        let values = Dictionary(
            uniqueKeysWithValues: try Row.fetchAll(
                database,
                sql: """
                    SELECT key, real_value
                    FROM clipboard_maintenance_metadata
                    WHERE key IN (
                        'lastMaintenanceSucceededAt',
                        'nextMaintenanceDeadline'
                    )
                    """
            ).compactMap { row -> (String, Double)? in
                guard let value: Double = row["real_value"] else {
                    return nil
                }
                return (row["key"], value)
            }
        )
        return MaintenanceScheduleSnapshot(
            lastSuccess: values["lastMaintenanceSucceededAt"],
            nextDeadline: values["nextMaintenanceDeadline"]
        )
    }

    static func restoreMaintenanceSchedule(
        _ snapshot: MaintenanceScheduleSnapshot,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                DELETE FROM clipboard_maintenance_metadata
                WHERE key IN (
                    'lastMaintenanceSucceededAt',
                    'nextMaintenanceDeadline'
                )
                """
        )
        for (key, value) in [
            ("lastMaintenanceSucceededAt", snapshot.lastSuccess),
            ("nextMaintenanceDeadline", snapshot.nextDeadline),
        ] {
            guard let value else { continue }
            try database.execute(
                sql: """
                    INSERT INTO clipboard_maintenance_metadata(
                        key, real_value
                    ) VALUES (?, ?)
                    """,
                arguments: [key, value]
            )
        }
    }

    private static func maintenanceRetryDelay(
        after failureCount: Int
    ) -> TimeInterval {
        let exponent = min(max(failureCount - 1, 0), 8)
        return min(
            initialMaintenanceRetryDelay * pow(2, Double(exponent)),
            maximumMaintenanceRetryDelay
        )
    }
}
