import Darwin
import Foundation
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryReleaseAcceptanceTests: XCTestCase {
    func testRemoveSyntheticGUIFixtureFromDefaultStore() async throws {
        guard ProcessInfo.processInfo.environment[
            "CLIPBOARD_HISTORY_REMOVE_GUI_FIXTURE"
        ] == "1" else {
            throw XCTSkip(
                "Set CLIPBOARD_HISTORY_REMOVE_GUI_FIXTURE=1 for explicit cleanup"
            )
        }
        let module = ClipboardHistoryModule()
        let status = await module.status()
        guard status.availability == .ready else {
            print(
                "CLIPBOARD_HISTORY_GUI_FIXTURE_CLEANUP_SKIPPED="
                    + "\(String(describing: status.reason))"
            )
            return
        }
        var removedCount = 0
        while true {
            let page = try await module.page(
                ClipboardHistoryQuery(text: "GUI fixture")
            )
            let syntheticEntries = page.entries.filter { entry in
                entry.previewText?.hasPrefix("GUI fixture ") == true
                    && (
                        entry.source.bundleIdentifier == "com.apple.Safari"
                            || entry.source.bundleIdentifier
                                == "com.apple.Notes"
                    )
            }
            guard !syntheticEntries.isEmpty else { break }
            for entry in syntheticEntries {
                let outcome = try await module.apply(.delete(entry.id))
                if outcome == .deleted {
                    removedCount += 1
                }
            }
        }
        print("CLIPBOARD_HISTORY_GUI_FIXTURE_REMOVED=\(removedCount)")
    }

    func testLargeCorpusSearchAndRetentionCharacterization() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CLIPBOARD_HISTORY_RELEASE_ACCEPTANCE"] == "1" else {
            throw XCTSkip(
                "Set CLIPBOARD_HISTORY_RELEASE_ACCEPTANCE=1 to run the release benchmark"
            )
        }
        let corpusSize = environment[
            "CLIPBOARD_HISTORY_ACCEPTANCE_CORPUS_SIZE"
        ].flatMap(Int.init) ?? 100_000
        let sampleCount = environment[
            "CLIPBOARD_HISTORY_ACCEPTANCE_SAMPLE_COUNT"
        ].flatMap(Int.init) ?? 20
        let maximumP95Milliseconds = environment[
            "CLIPBOARD_HISTORY_ACCEPTANCE_MAX_P95_MS"
        ].flatMap(Double.init) ?? 250
        let maximumRSSDeltaBytes = UInt64(
            environment[
                "CLIPBOARD_HISTORY_ACCEPTANCE_MAX_RSS_MIB"
            ].flatMap(Int.init) ?? 256
        ) * 1_024 * 1_024

        let fixture = try ReleaseAcceptanceStore()
        let clock = ReleaseAcceptanceClock(
            Date(timeIntervalSince1970: 1_900_000_000)
        )
        let module = fixture.makeModule(clock: clock)
        let corpusStarted = ContinuousClock.now
        for index in 0..<corpusSize {
            let marker: String
            switch index {
            case let value where value.isMultiple(of: 97):
                marker = "甲"
            case let value where value.isMultiple(of: 89):
                marker = "乙丙"
            case let value where value.isMultiple(of: 113):
                marker = "interplanetary-substring"
            default:
                marker = "ordinary"
            }
            _ = try await module.capture(
                ClipboardHistoryCaptureRequest(
                    source: .unknown,
                    content: .text(
                        "entry-\(index) deterministic payload \(marker)"
                    )
                )
            )
        }
        let corpusSeconds = Self.seconds(since: corpusStarted)

        let rssBeforeQueries = try Self.residentSize()
        var queryResults: [String: QueryMeasurement] = [:]
        for query in [
            ("empty", ""),
            ("oneCharacter", "甲"),
            ("twoCharacter", "乙丙"),
            ("longSubstring", "interplanetary-substring"),
        ] {
            queryResults[query.0] = try await Self.measureQuery(
                ClipboardHistoryQuery(text: query.1),
                sampleCount: sampleCount,
                module: module
            )
        }
        let rssAfterQueries = try Self.residentSize()
        let rssDelta = rssAfterQueries > rssBeforeQueries
            ? rssAfterQueries - rssBeforeQueries
            : 0

        for (name, result) in queryResults {
            XCTAssertLessThanOrEqual(
                result.p95Milliseconds,
                maximumP95Milliseconds,
                "\(name) search p95 exceeded the interactive threshold"
            )
        }
        XCTAssertLessThanOrEqual(
            rssDelta,
            maximumRSSDeltaBytes,
            "Search RSS delta exceeded the acceptance threshold"
        )

        clock.now = clock.now.addingTimeInterval(31 * 86_400)
        let cleanupStarted = ContinuousClock.now
        let report = try await module.performMaintenance(orphanGracePeriod: 0)
        let cleanupMilliseconds =
            Self.seconds(since: cleanupStarted) * 1_000
        let remainingCount = try await module.count(.init())
        XCTAssertEqual(remainingCount, 0)

        let output = ReleaseAcceptanceOutput(
            corpusSize: corpusSize,
            corpusBuildSeconds: corpusSeconds,
            queryMeasurements: queryResults,
            queryRSSBeforeBytes: rssBeforeQueries,
            queryRSSAfterBytes: rssAfterQueries,
            queryRSSDeltaBytes: rssDelta,
            retentionCleanupMilliseconds: cleanupMilliseconds,
            retentionRemainingCount: remainingCount,
            retainedStorageBytes: report.storageBytes
        )
        let data = try JSONEncoder.acceptance.encode(output)
        print(
            "CLIPBOARD_HISTORY_RELEASE_ACCEPTANCE_JSON="
                + String(decoding: data, as: UTF8.self)
        )
    }

    private static func measureQuery(
        _ query: ClipboardHistoryQuery,
        sampleCount: Int,
        module: ClipboardHistoryModule
    ) async throws -> QueryMeasurement {
        let coldStarted = ContinuousClock.now
        let coldPage = try await module.page(query)
        let coldMilliseconds = seconds(since: coldStarted) * 1_000
        var warmMilliseconds: [Double] = []
        warmMilliseconds.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let started = ContinuousClock.now
            _ = try await module.page(query)
            warmMilliseconds.append(seconds(since: started) * 1_000)
        }
        let sorted = warmMilliseconds.sorted()
        let p50 = percentile(0.50, in: sorted)
        let p95 = percentile(0.95, in: sorted)
        return QueryMeasurement(
            coldMilliseconds: coldMilliseconds,
            p50Milliseconds: p50,
            p95Milliseconds: p95,
            maximumMilliseconds: sorted.last ?? coldMilliseconds,
            firstPageCount: coldPage.entries.count
        )
    }

    private static func percentile(
        _ percentile: Double,
        in sortedValues: [Double]
    ) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let index = min(
            Int(ceil(Double(sortedValues.count) * percentile)) - 1,
            sortedValues.count - 1
        )
        return sortedValues[max(index, 0)]
    }

    private static func seconds(
        since start: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    private static func residentSize() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw ReleaseAcceptanceError.taskInfo(result)
        }
        return UInt64(info.resident_size)
    }
}

private struct QueryMeasurement: Codable {
    let coldMilliseconds: Double
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maximumMilliseconds: Double
    let firstPageCount: Int
}

private struct ReleaseAcceptanceOutput: Codable {
    let corpusSize: Int
    let corpusBuildSeconds: Double
    let queryMeasurements: [String: QueryMeasurement]
    let queryRSSBeforeBytes: UInt64
    let queryRSSAfterBytes: UInt64
    let queryRSSDeltaBytes: UInt64
    let retentionCleanupMilliseconds: Double
    let retentionRemainingCount: Int
    let retainedStorageBytes: UInt64
}

private enum ReleaseAcceptanceError: Error {
    case taskInfo(kern_return_t)
}

private extension JSONEncoder {
    static var acceptance: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private final class ReleaseAcceptanceStore {
    let url: URL
    private let keyStore = ReleaseAcceptanceKeyStore()

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnyDoor-ClipboardReleaseAcceptance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func makeModule(
        clock: ReleaseAcceptanceClock
    ) -> ClipboardHistoryModule {
        ClipboardHistoryModule(
            testingStoreRoot: url,
            keyStore: keyStore,
            now: { clock.now }
        )
    }
}

private final class ReleaseAcceptanceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    var now: Date {
        get {
            lock.withLock { value }
        }
        set {
            lock.withLock { value = newValue }
        }
    }

    init(_ now: Date) {
        value = now
    }
}

private struct ReleaseAcceptanceKeyStore:
    ClipboardHistoryMasterKeyStoring
{
    private static let key = Data(repeating: 0x91, count: 32)

    func load() -> ClipboardHistoryMasterKeyResult {
        .key(Self.key)
    }

    func create() -> ClipboardHistoryMasterKeyResult {
        .key(Self.key)
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        .missing
    }
}
