import XCTest
@testable import AnyDoor

/// Deterministic RNG so property-test failures reproduce from the seed.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class SyncDocumentMergeTests: XCTestCase {

    private func ts(_ wall: Int64, _ counter: Int = 0, _ device: String = "a") -> SyncTimestamp {
        SyncTimestamp(wallMillis: wall, counter: counter, deviceID: device)
    }

    private func doc(_ device: String, _ entries: [SyncKey: SyncEntry]) -> SyncDocument {
        SyncDocument(deviceID: device, entries: entries)
    }

    // MARK: - Directed cases

    func testNewerClockWinsPerKey() {
        let key = SyncKey.setting(key: "menuBar.iconVisible")
        let old = SyncEntry(payload: .setting(.bool(true)), clock: ts(100))
        let new = SyncEntry(payload: .setting(.bool(false)), clock: ts(200, 0, "b"))
        let merged = doc("a", [key: old]).merged(with: doc("b", [key: new]))
        XCTAssertEqual(merged.entries[key], new)
        XCTAssertEqual(merged.deviceID, "a", "merge keeps the local document's identity")
    }

    func testDisjointKeysBothSurvive() {
        let k1 = SyncKey.setting(key: "one")
        let k2 = SyncKey.setting(key: "two")
        let e1 = SyncEntry(payload: .setting(.int(1)), clock: ts(100))
        let e2 = SyncEntry(payload: .setting(.int(2)), clock: ts(100, 0, "b"))
        let merged = doc("a", [k1: e1]).merged(with: doc("b", [k2: e2]))
        XCTAssertEqual(merged.entries[k1], e1)
        XCTAssertEqual(merged.entries[k2], e2)
    }

    func testNewerTombstoneDeletesOlderPayload() {
        let key = SyncKey.quicklink(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let alive = SyncEntry(payload: .setting(.int(1)), clock: ts(100))
        let tombstone = SyncEntry(payload: nil, clock: ts(200, 0, "b"))
        let merged = doc("a", [key: alive]).merged(with: doc("b", [key: tombstone]))
        XCTAssertEqual(merged.entries[key]?.isTombstone, true)
    }

    func testNewerPayloadBeatsOlderTombstone() {
        let key = SyncKey.setting(key: "re-added")
        let tombstone = SyncEntry(payload: nil, clock: ts(100))
        let readded = SyncEntry(payload: .setting(.int(7)), clock: ts(200, 0, "b"))
        let merged = doc("a", [key: tombstone]).merged(with: doc("b", [key: readded]))
        XCTAssertEqual(merged.entries[key], readded)
    }

    func testPruneRemovesOnlyExpiredTombstones() {
        let expired = SyncKey.setting(key: "expired")
        let fresh = SyncKey.setting(key: "fresh")
        let live = SyncKey.setting(key: "live")
        let document = doc("a", [
            expired: SyncEntry(payload: nil, clock: ts(100)),
            fresh: SyncEntry(payload: nil, clock: ts(900)),
            // A live entry older than the cutoff must never be pruned.
            live: SyncEntry(payload: .setting(.int(1)), clock: ts(50)),
        ])
        let pruned = document.prunedTombstones(before: 500)
        XCTAssertNil(pruned.entries[expired])
        XCTAssertNotNil(pruned.entries[fresh])
        XCTAssertNotNil(pruned.entries[live])
    }

    func testCodableRoundTripAndUnknownKeyTolerance() throws {
        let known = SyncKey.appShortcut(bundleID: "com.apple.Safari")
        let shortcut = AppShortcutDTO(
            appBundleID: "com.apple.Safari", appName: "Safari",
            keyCode: 4, modifierFlags: 256,
            isEnabled: true, isVisible: true, displayOrder: 100
        )
        let document = doc("a", [
            known: SyncEntry(payload: .appShortcut(shortcut), clock: ts(100)),
            .setting(key: "x"): SyncEntry(payload: nil, clock: ts(200)),
        ])
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(SyncDocument.self, from: data)
        XCTAssertEqual(decoded, document)

        // Inject a record kind this build doesn't know: the document must
        // still decode, dropping only that record.
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var entries = try XCTUnwrap(json["entries"] as? [String: Any])
        entries["futureKind:whatever"] = [
            "clock": ["wallMillis": 1, "counter": 0, "deviceID": "z"]
        ]
        json["entries"] = entries
        let patched = try JSONSerialization.data(withJSONObject: json)
        let tolerant = try JSONDecoder().decode(SyncDocument.self, from: patched)
        XCTAssertEqual(tolerant.entries, document.entries)
    }

    // MARK: - Merge algebra (seeded property tests)

    /// Random documents share a version pool per key, so two documents can
    /// hold the identical entry (converged earlier), competing versions of a
    /// key, or miss it entirely — while distinct edits always carry distinct
    /// clocks, which is what `SyncClock` guarantees in production.
    private func randomDocuments(
        count: Int,
        using rng: inout SplitMix64
    ) -> [SyncDocument] {
        let keys: [SyncKey] = (0..<8).map { .setting(key: "k\($0)") }
        var versionsByKey: [SyncKey: [SyncEntry]] = [:]
        var edit = 0
        for key in keys {
            let versionCount = Int.random(in: 1...4, using: &rng)
            versionsByKey[key] = (0..<versionCount).map { _ in
                edit += 1
                let payload: SyncPayload? =
                    Bool.random(using: &rng) ? .setting(.int(edit)) : nil
                return SyncEntry(
                    payload: payload,
                    clock: SyncTimestamp(
                        wallMillis: Int64.random(in: 0...5, using: &rng),
                        counter: edit,
                        deviceID: ["a", "b", "c"].randomElement(using: &rng)!
                    )
                )
            }
        }
        return (0..<count).map { index in
            var entries: [SyncKey: SyncEntry] = [:]
            for key in keys where Bool.random(using: &rng) {
                entries[key] = versionsByKey[key]!.randomElement(using: &rng)!
            }
            return SyncDocument(deviceID: "device-\(index)", entries: entries)
        }
    }

    func testMergeIsCommutativeAssociativeIdempotent() {
        var rng = SplitMix64(state: 0xDEAD_BEEF)
        for iteration in 0..<300 {
            let docs = randomDocuments(count: 3, using: &rng)
            let (a, b, c) = (docs[0], docs[1], docs[2])

            XCTAssertEqual(
                a.merged(with: b).entries, b.merged(with: a).entries,
                "commutativity failed at iteration \(iteration)"
            )
            XCTAssertEqual(
                a.merged(with: b).merged(with: c).entries,
                a.merged(with: b.merged(with: c)).entries,
                "associativity failed at iteration \(iteration)"
            )
            XCTAssertEqual(
                a.merged(with: a).entries, a.entries,
                "self-idempotence failed at iteration \(iteration)"
            )
            XCTAssertEqual(
                a.merged(with: b).merged(with: b).entries,
                a.merged(with: b).entries,
                "re-merge idempotence failed at iteration \(iteration)"
            )
        }
    }

    func testAllMergeOrdersConverge() {
        var rng = SplitMix64(state: 0xC0FF_EE00)
        for iteration in 0..<100 {
            let docs = randomDocuments(count: 4, using: &rng)
            var orders: Set<[Int]> = []
            var permutation = [0, 1, 2, 3]
            // All 24 permutations via simple next-permutation loop is
            // overkill; a handful of shuffles covers the algebra.
            for _ in 0..<6 {
                permutation.shuffle(using: &rng)
                orders.insert(permutation)
            }
            let results = orders.map { order in
                order.dropFirst().reduce(docs[order[0]]) { acc, index in
                    acc.merged(with: docs[index])
                }.entries
            }
            for result in results.dropFirst() {
                XCTAssertEqual(
                    result, results[0],
                    "merge order changed the outcome at iteration \(iteration)"
                )
            }
        }
    }
}
