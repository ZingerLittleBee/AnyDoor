import Foundation
import GRDB
import SQLCipher
import os

/// Counts actual SQLCipher VM instructions while the public module runs.
/// Preparation retains this observer for each connection's lifetime; no SQL
/// arguments or statement text leave the profile callback.
final class ClipboardHistorySQLWorkProbe: Sendable {
    private struct State { var enabled = false; var steps: Int64 = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let table: String

    init(table: String) { self.table = table }

    func install(on database: Database) {
        sqlite3_trace_v2(database.sqliteConnection, UInt32(SQLITE_TRACE_PROFILE), { _, context, pointer, _ in
            guard let context, let pointer else { return 0 }
            let statement = OpaquePointer(pointer)
            // Prepared statements are reused: reset at every completed execution,
            // even outside the measurement window, so totals never accumulate twice.
            let steps = sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1)
            let observer = Unmanaged<ClipboardHistorySQLWorkProbe>.fromOpaque(context).takeUnretainedValue()
            if let sql = sqlite3_sql(statement) { observer.record(sql: sql, steps: steps) }
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func start() { state.withLock { $0.enabled = true; $0.steps = 0 } }
    func stop() -> Int64 { state.withLock { $0.enabled = false; return $0.steps } }

    private func record(sql: UnsafePointer<CChar>, steps: Int32) {
        let matches = String(cString: sql).contains(table)
        state.withLock { value in
            guard value.enabled, matches else { return }
            value.steps += Int64(steps)
        }
    }
}
