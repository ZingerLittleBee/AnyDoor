import Foundation

/// Hybrid logical clock timestamp attached to every Sync Document entry.
/// Total order: wall time, then logical counter, then device id — so any two
/// distinct edits anywhere compare deterministically and LWW merge needs no
/// conflict UI (ADR-0010).
struct SyncTimestamp: Codable, Equatable, Hashable, Comparable, Sendable {
    /// Milliseconds since 1970 as observed by the issuing device.
    var wallMillis: Int64
    /// Logical counter disambiguating same-millisecond issues and carrying
    /// causality when a wall clock stalls or regresses.
    var counter: Int
    /// Stable id of the issuing device; the final tie-break.
    var deviceID: String

    static func < (lhs: SyncTimestamp, rhs: SyncTimestamp) -> Bool {
        if lhs.wallMillis != rhs.wallMillis { return lhs.wallMillis < rhs.wallMillis }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.deviceID < rhs.deviceID
    }
}

/// Issues monotonically increasing `SyncTimestamp`s for one device.
///
/// The two HLC rules:
/// - `now(wallMillis:)` — local edit: advance to the wall clock if it moved
///   forward, otherwise keep the last wall time and bump the counter (this is
///   the wall-regression defense: a clock jumping backwards can never issue a
///   timestamp that loses to our own past).
/// - `observe(_:)` — merged a remote entry: ensure everything issued later
///   outranks it, so an edit made after seeing remote state wins over it.
struct SyncClock: Codable, Equatable, Sendable {
    let deviceID: String
    private var lastWallMillis: Int64
    private var lastCounter: Int

    init(deviceID: String) {
        self.deviceID = deviceID
        self.lastWallMillis = 0
        self.lastCounter = 0
    }

    mutating func now(wallMillis: Int64) -> SyncTimestamp {
        if wallMillis > lastWallMillis {
            lastWallMillis = wallMillis
            lastCounter = 0
        } else {
            lastCounter += 1
        }
        return SyncTimestamp(
            wallMillis: lastWallMillis,
            counter: lastCounter,
            deviceID: deviceID
        )
    }

    mutating func observe(_ remote: SyncTimestamp) {
        if remote.wallMillis > lastWallMillis {
            lastWallMillis = remote.wallMillis
            lastCounter = remote.counter
        } else if remote.wallMillis == lastWallMillis {
            lastCounter = max(lastCounter, remote.counter)
        }
    }
}
