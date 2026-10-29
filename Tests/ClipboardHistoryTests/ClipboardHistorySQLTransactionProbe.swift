import GRDB
import SQLCipher
import os

/// Observes transaction boundaries on the real SQLCipher connections. No SQL
/// values or statement text are retained, only outbox insert counts per commit.
final class ClipboardHistorySQLTransactionProbe: Sendable {
    struct Counts { let total: Int; let largestCommit: Int }
    private struct State {
        var enabled = false
        var current: [UInt: Int] = [:]
        var total = 0
        var largest = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(on database: Database) {
        sqlite3_trace_v2(database.sqliteConnection, UInt32(SQLITE_TRACE_PROFILE), { _, context, pointer, _ in
            guard let context, let pointer else { return 0 }
            let statement = OpaquePointer(pointer)
            guard let connection = sqlite3_db_handle(statement), let sql = sqlite3_sql(statement) else { return 0 }
            let observer = Unmanaged<ClipboardHistorySQLTransactionProbe>.fromOpaque(context).takeUnretainedValue()
            observer.record(connection: UInt(bitPattern: connection), sql: String(cString: sql),
                ended: sqlite3_get_autocommit(connection) != 0)
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func start() { state.withLock { $0 = State(); $0.enabled = true } }
    func stop() -> Counts { state.withLock { $0.enabled = false; return Counts(total: $0.total, largestCommit: $0.largest) } }

    private func record(connection: UInt, sql: String, ended: Bool) {
        let insertsOutbox = sql.hasPrefix("INSERT INTO clipboard_sync_outbox(")
        state.withLock { value in
            guard value.enabled else { return }
            if insertsOutbox { value.total += 1; value.current[connection, default: 0] += 1 }
            if ended {
                value.largest = max(value.largest, value.current.removeValue(forKey: connection) ?? 0)
            }
        }
    }
}
