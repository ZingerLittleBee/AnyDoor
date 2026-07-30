import AppKit
import XCTest
import GRDB

@testable import ClipboardHistory

final class ClipboardHistoryMonitorSchedulerTests: XCTestCase {
    func testIdleFallbackAndOverlappingKeyHintsUseOneCoalescedSchedule() {
        var scheduler = ClipboardHistoryMonitorScheduler()

        let started = scheduler.handle(.setEnabled(true), at: .milliseconds(0))
        XCTAssertTrue(started.establishBaseline)
        XCTAssertFalse(started.observeNow)
        XCTAssertEqual(
            started.nextFire,
            .init(deadline: .milliseconds(500), tolerance: .milliseconds(50))
        )

        let firstHint = scheduler.handle(.keyHint, at: .milliseconds(100))
        XCTAssertFalse(firstHint.establishBaseline)
        XCTAssertTrue(firstHint.observeNow)
        XCTAssertEqual(
            firstHint.copyEventWindowDeadline,
            .milliseconds(600)
        )
        XCTAssertEqual(
            firstHint.nextFire,
            .init(deadline: .milliseconds(150), tolerance: .milliseconds(5))
        )

        let overlappingHint = scheduler.handle(.keyHint, at: .milliseconds(125))
        XCTAssertTrue(overlappingHint.observeNow)
        XCTAssertEqual(
            overlappingHint.copyEventWindowDeadline,
            .milliseconds(625)
        )
        XCTAssertEqual(
            overlappingHint.nextFire,
            .init(deadline: .milliseconds(175), tolerance: .milliseconds(5))
        )

        let burstTick = scheduler.handle(.timerFired, at: .milliseconds(175))
        XCTAssertTrue(burstTick.observeNow)
        XCTAssertEqual(
            burstTick.nextFire,
            .init(deadline: .milliseconds(225), tolerance: .milliseconds(5))
        )

        let idleTick = scheduler.handle(.timerFired, at: .milliseconds(675))
        XCTAssertTrue(idleTick.observeNow)
        XCTAssertNil(idleTick.copyEventWindowDeadline)
        XCTAssertEqual(
            idleTick.nextFire,
            .init(deadline: .milliseconds(1_175), tolerance: .milliseconds(50))
        )
    }

    func testNonKeyboardChangeStartsABriefPostChangeBoost() {
        var scheduler = ClipboardHistoryMonitorScheduler()
        _ = scheduler.handle(.setEnabled(true), at: .milliseconds(0))

        let fallback = scheduler.handle(.timerFired, at: .milliseconds(500))
        XCTAssertTrue(fallback.observeNow)
        let changed = scheduler.handle(
            .observationCompleted(changed: true),
            at: .milliseconds(510)
        )
        XCTAssertEqual(
            changed.nextFire,
            .init(deadline: .milliseconds(610), tolerance: .milliseconds(10))
        )

        let boosted = scheduler.handle(.timerFired, at: .milliseconds(610))
        XCTAssertTrue(boosted.observeNow)
        XCTAssertEqual(
            boosted.nextFire,
            .init(deadline: .milliseconds(710), tolerance: .milliseconds(10))
        )

        let backToIdle = scheduler.handle(.timerFired, at: .milliseconds(1_110))
        XCTAssertEqual(
            backToIdle.nextFire,
            .init(deadline: .milliseconds(1_610), tolerance: .milliseconds(50))
        )
    }

    func testStopSleepLockWakeUnlockAndMigrationResumeFromBaseline() {
        var scheduler = ClipboardHistoryMonitorScheduler()
        XCTAssertTrue(
            scheduler.handle(.setEnabled(true), at: .milliseconds(0))
                .establishBaseline
        )

        XCTAssertNil(
            scheduler.handle(.willSleep, at: .milliseconds(100)).nextFire
        )
        XCTAssertTrue(
            scheduler.handle(.didWake, at: .milliseconds(1_000))
                .establishBaseline
        )

        XCTAssertNil(
            scheduler.handle(.screenLocked, at: .milliseconds(1_100)).nextFire
        )
        XCTAssertTrue(
            scheduler.handle(.screenUnlocked, at: .milliseconds(2_000))
                .establishBaseline
        )

        XCTAssertNil(
            scheduler.handle(.migrationStarted, at: .milliseconds(2_100))
                .nextFire
        )
        XCTAssertTrue(
            scheduler.handle(.migrationCompleted, at: .milliseconds(3_000))
                .establishBaseline
        )

        let stopped = scheduler.handle(
            .setEnabled(false),
            at: .milliseconds(3_100)
        )
        XCTAssertNil(stopped.nextFire)
        XCTAssertFalse(
            scheduler.handle(.keyHint, at: .milliseconds(3_200)).observeNow
        )
        XCTAssertTrue(
            scheduler.handle(.setEnabled(true), at: .milliseconds(4_000))
                .establishBaseline
        )
    }

    func testIdleFallbackNeverSchedulesMoreThanTwoFiresPerSecond() {
        var scheduler = ClipboardHistoryMonitorScheduler()
        var plan = scheduler.handle(.setEnabled(true), at: .zero)
        var fireTimes: [Duration] = []

        for _ in 0..<20 {
            guard let fire = plan.nextFire else {
                return XCTFail("Expected the idle fallback to remain scheduled")
            }
            XCTAssertGreaterThanOrEqual(
                fire.tolerance,
                .milliseconds(50)
            )
            fireTimes.append(fire.deadline)
            plan = scheduler.handle(.timerFired, at: fire.deadline)
        }

        for second in 0..<10 {
            let lower = Duration.seconds(second)
            let upper = Duration.seconds(second + 1)
            let count = fireTimes.filter { $0 > lower && $0 <= upper }.count
            XCTAssertLessThanOrEqual(count, 2)
        }
    }
}

final class ClipboardHistoryObservationPolicyTests: XCTestCase {
    func testSourcePrecedencePreservesUniversalDeclaredHintInferredAndUnknown() {
        let policy = ClipboardHistoryObservationPolicy()
        let copySource = ClipboardHistoryApplicationSource(
            bundleIdentifier: "dev.bybee.copy",
            displayName: "Copy App"
        )
        let observedSource = ClipboardHistoryApplicationSource(
            bundleIdentifier: "dev.bybee.observed",
            displayName: "Observed App"
        )

        XCTAssertEqual(
            policy.evaluate(
                .init(
                    generation: 1,
                    advertisedTypeIdentifiers: ["com.apple.is-remote-clipboard"],
                    declaredSourceBundleIdentifier: "dev.bybee.declared"
                ),
                copyEventSource: copySource,
                observationSource: observedSource,
                configuration: .init()
            ),
            .capture(.universalClipboard)
        )
        XCTAssertEqual(
            policy.evaluate(
                .init(
                    generation: 2,
                    advertisedTypeIdentifiers: [],
                    declaredSourceBundleIdentifier: "dev.bybee.declared"
                ),
                copyEventSource: copySource,
                observationSource: observedSource,
                configuration: .init()
            ),
            .capture(
                .init(
                    bundleIdentifier: "dev.bybee.declared",
                    displayName: nil,
                    provenance: .declared
                )
            )
        )
        XCTAssertEqual(
            policy.evaluate(
                .init(generation: 3, advertisedTypeIdentifiers: []),
                copyEventSource: copySource,
                observationSource: observedSource,
                configuration: .init()
            ),
            .capture(
                .init(
                    bundleIdentifier: "dev.bybee.copy",
                    displayName: "Copy App",
                    provenance: .copyEvent
                )
            )
        )
        XCTAssertEqual(
            policy.evaluate(
                .init(generation: 4, advertisedTypeIdentifiers: []),
                copyEventSource: nil,
                observationSource: observedSource,
                configuration: .init()
            ),
            .capture(
                .init(
                    bundleIdentifier: "dev.bybee.observed",
                    displayName: "Observed App",
                    provenance: .observation
                )
            )
        )
        XCTAssertEqual(
            policy.evaluate(
                .init(generation: 5, advertisedTypeIdentifiers: []),
                copyEventSource: nil,
                observationSource: nil,
                configuration: .init()
            ),
            .capture(.unknown)
        )
    }

    func testMarkersAndFutureSourceRulesAreExcludedBeforeCapture() {
        let policy = ClipboardHistoryObservationPolicy()
        let excluded = ClipboardHistoryMonitoringConfiguration(
            excludedBundleIdentifiers: ["dev.bybee.secret"],
            ignoresUniversalClipboard: true
        )

        for marker in ClipboardHistoryObservationPolicy.exclusionTypeIdentifiers {
            XCTAssertEqual(
                policy.evaluate(
                    .init(
                        generation: 1,
                        advertisedTypeIdentifiers: [marker]
                    ),
                    copyEventSource: nil,
                    observationSource: nil,
                    configuration: .init()
                ),
                .exclude
            )
        }
        XCTAssertEqual(
            policy.evaluate(
                .init(
                    generation: 2,
                    advertisedTypeIdentifiers: [],
                    declaredSourceBundleIdentifier: "dev.bybee.secret"
                ),
                copyEventSource: nil,
                observationSource: nil,
                configuration: excluded
            ),
            .exclude
        )
        XCTAssertEqual(
            policy.evaluate(
                .init(
                    generation: 3,
                    advertisedTypeIdentifiers: ["com.apple.is-remote-clipboard"]
                ),
                copyEventSource: nil,
                observationSource: nil,
                configuration: excluded
            ),
            .exclude
        )
    }
}

final class ClipboardHistorySelfWriteSuppressionTests: XCTestCase {
    func testOneFunnelSuppressesCompletedAndIntermediateGenerations() {
        let suppression = ClipboardHistorySelfWriteSuppression()
        let token = suppression.begin()

        XCTAssertTrue(suppression.shouldSuppress(generation: 10))
        token.finish(generation: 12)
        XCTAssertTrue(suppression.shouldSuppress(generation: 12))
        XCTAssertTrue(suppression.shouldSuppress(generation: 12))
        XCTAssertFalse(suppression.shouldSuppress(generation: 13))
    }
}

final class ClipboardHistoryMonitorInstrumentationTests: XCTestCase {
    func testMetricsSeparateIdleWakeupsFromBoostedObservationsAndOverwrites() {
        let instrumentation = ClipboardHistoryMonitorInstrumentation()
        instrumentation.recordKeyHint()
        instrumentation.recordTimerFire(isIdle: true)
        instrumentation.recordTimerFire(isIdle: true)
        instrumentation.recordTimerFire(isIdle: false)
        instrumentation.recordObservedGeneration(
            previous: 7,
            current: 10
        )
        instrumentation.recordCapture()

        XCTAssertEqual(
            instrumentation.snapshot(),
            ClipboardHistoryMonitorMetrics(
                keyHintCount: 1,
                idleTimerFireCount: 2,
                boostedTimerFireCount: 1,
                observedChangeCount: 1,
                capturedChangeCount: 1,
                overwrittenGenerationCount: 2
            )
        )
    }
}

final class ClipboardHistorySourcePersistenceTests: XCTestCase {
    func testCaptureAndDuplicateReusePersistLatestSourceProvenance() async throws {
        let fixture = try MonitorTemporaryStore()
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: MonitorMemoryKeyStore()
        )
        let first = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .init(
                    bundleIdentifier: "dev.bybee.declared",
                    displayName: "Declared",
                    provenance: .declared
                ),
                content: .text("same")
            )
        )
        _ = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .init(
                    bundleIdentifier: "dev.bybee.copy",
                    displayName: "Copy",
                    provenance: .copyEvent
                ),
                content: .text("same")
            )
        )

        let database = try await module.requiredDatabase()
        let provenance = try await database.read { database in
            try String.fetchOne(
                database,
                sql: """
                    SELECT source_provenance
                    FROM clipboard_entries
                    WHERE id = ?
                    """,
                arguments: [first.entryID.value.uuidString.lowercased()]
            )
        }
        XCTAssertEqual(provenance, "copyEvent")
    }
}

final class ClipboardHistoryCaptureMonitorTests: XCTestCase {
    @MainActor
    func testBaselineResumeAndSelfWritesNeverImportCurrentPasteboard() async throws {
        let fixture = try MonitorTemporaryStore()
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: MonitorMemoryKeyStore()
        )
        let pasteboard = NSPasteboard(
            name: .init("dev.bybee.AnyDoor.monitor.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setString("before launch", forType: .string)
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            installsSystemObservers: false
        )

        await monitor.setEnabled(true)
        var page = try await module.page(.init())
        XCTAssertEqual(page.entries, [])

        pasteboard.clearContents()
        pasteboard.setString("first observed", forType: .string)
        await monitor.observeForTesting()
        page = try await module.page(.init())
        XCTAssertEqual(page.entries.count, 1)

        let token = module.pasteboardSelfWrites.begin()
        pasteboard.clearContents()
        pasteboard.setString("AnyDoor write", forType: .string)
        token.finish(pasteboard: pasteboard)
        await monitor.observeForTesting()
        page = try await module.page(.init())
        XCTAssertEqual(page.entries.count, 1)

        await monitor.handleLifecycle(.willSleep)
        pasteboard.clearContents()
        pasteboard.setString("while asleep", forType: .string)
        await monitor.observeForTesting()
        await monitor.handleLifecycle(.didWake)
        page = try await module.page(.init())
        XCTAssertEqual(page.entries.count, 1)

        pasteboard.clearContents()
        pasteboard.setString("after wake", forType: .string)
        await monitor.observeForTesting()
        page = try await module.page(.init())
        XCTAssertEqual(page.entries.count, 2)
    }

    @MainActor
    func testKeyWindowObservesConsecutiveCopiesWithSampledSource() async throws {
        let fixture = try MonitorTemporaryStore()
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: MonitorMemoryKeyStore()
        )
        let pasteboard = NSPasteboard(
            name: .init("dev.bybee.AnyDoor.monitor.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let sampledSource = ClipboardHistoryApplicationSource(
            bundleIdentifier: "dev.bybee.editor",
            displayName: "Editor"
        )
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            sourceProvider: { sampledSource },
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        await monitor.keyHintForTesting()
        pasteboard.clearContents()
        pasteboard.setString("first", forType: .string)
        await monitor.timerFiredForTesting()

        await monitor.keyHintForTesting()
        pasteboard.clearContents()
        pasteboard.setString("second", forType: .string)
        await monitor.timerFiredForTesting()

        let page = try await module.page(.init())
        XCTAssertEqual(Set(page.entries.compactMap(\.previewText)), ["first", "second"])
        let database = try await module.requiredDatabase()
        let provenances = try await database.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT source_provenance
                    FROM clipboard_entries
                    ORDER BY captured_at
                    """
            )
        }
        XCTAssertEqual(provenances, ["copyEvent", "copyEvent"])
    }

    @MainActor
    func testExpiredKeyHintUsesObservationSourceForNextChange() async throws {
        let fixture = try MonitorTemporaryStore()
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: MonitorMemoryKeyStore()
        )
        let pasteboard = NSPasteboard(
            name: .init("dev.bybee.AnyDoor.monitor.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let clock = MonitorTestClock()
        var sourceSamples: [ClipboardHistoryApplicationSource?] = [
            ClipboardHistoryApplicationSource(
                bundleIdentifier: "dev.bybee.copy",
                displayName: "Copy App"
            ),
            ClipboardHistoryApplicationSource(
                bundleIdentifier: "dev.bybee.observed",
                displayName: "Observed App"
            ),
        ]
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            sourceProvider: { sourceSamples.removeFirst() },
            now: { clock.now },
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        await monitor.keyHintForTesting()
        clock.now = .milliseconds(501)
        pasteboard.clearContents()
        pasteboard.setString("menu copy", forType: .string)
        await monitor.observeForTesting()

        let page = try await module.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(
            entry.source,
            ClipboardHistoryCaptureSource(
                bundleIdentifier: "dev.bybee.observed",
                displayName: "Observed App",
                provenance: .observation
            )
        )
    }

    @MainActor
    func testExpiredKeyHintUsesUnknownWithoutObservationSource() async throws {
        let fixture = try MonitorTemporaryStore()
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: MonitorMemoryKeyStore()
        )
        let pasteboard = NSPasteboard(
            name: .init("dev.bybee.AnyDoor.monitor.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        let clock = MonitorTestClock()
        var sourceSamples: [ClipboardHistoryApplicationSource?] = [
            ClipboardHistoryApplicationSource(
                bundleIdentifier: "dev.bybee.copy",
                displayName: "Copy App"
            ),
            nil,
        ]
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            sourceProvider: { sourceSamples.removeFirst() },
            now: { clock.now },
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        await monitor.keyHintForTesting()
        clock.now = .milliseconds(501)
        pasteboard.clearContents()
        pasteboard.setString("programmatic copy", forType: .string)
        await monitor.observeForTesting()

        let page = try await module.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(entry.source, .unknown)
    }

    @MainActor
    func testExplicitBaselineAdvanceSkipsUnchangedLivePasteboard()
        async throws
    {
        let fixture = try MonitorTemporaryStore()
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: MonitorMemoryKeyStore()
        )
        let pasteboard = NSPasteboard(
            name: .init("dev.bybee.AnyDoor.monitor.\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        pasteboard.setString("initial", forType: .string)
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)
        pasteboard.clearContents()
        pasteboard.setString(
            "present while history is cleared",
            forType: .string
        )

        monitor.establishBaseline()
        await monitor.observeForTesting()

        let page = try await module.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
    }

    @MainActor
    func testGenerationChangeBeforeSnapshotRetriesWithoutMixingSourceAndContent()
        async throws
    {
        let fixture = try MonitorTemporaryStore()
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: MonitorMemoryKeyStore()
        )
        let pasteboard = NSPasteboard(
            name: .init("dev.bybee.AnyDoor.monitor.\(UUID().uuidString)")
        )
        writeMonitorPasteboard(
            pasteboard,
            text: "baseline",
            declaredSource: "dev.bybee.baseline"
        )
        var requestedGenerations: [Int] = []
        var shouldReplaceGeneration = true
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            snapshotRequest: { pasteboard, generation in
                requestedGenerations.append(generation)
                if shouldReplaceGeneration {
                    shouldReplaceGeneration = false
                    self.writeMonitorPasteboard(
                        pasteboard,
                        text: "latest stable",
                        declaredSource: "dev.bybee.latest"
                    )
                }
                return ClipboardHistoryPasteboardCaptureRequest(
                    pasteboard: pasteboard,
                    expectedGeneration: generation
                )
            },
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        writeMonitorPasteboard(
            pasteboard,
            text: "overwritten during snapshot",
            declaredSource: "dev.bybee.overwritten"
        )
        let overwrittenGeneration = pasteboard.changeCount
        await monitor.observeForTesting()

        let page = try await module.page(.init())
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(entry.previewText, "latest stable")
        XCTAssertEqual(
            entry.source.bundleIdentifier,
            "dev.bybee.latest"
        )
        XCTAssertEqual(entry.source.provenance, .declared)
        XCTAssertEqual(
            requestedGenerations,
            [overwrittenGeneration, pasteboard.changeCount]
        )
    }

    @MainActor
    func testGenerationChangeDuringSnapshotRetriesLatestStableGeneration()
        async throws
    {
        let fixture = try MonitorTemporaryStore()
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: MonitorMemoryKeyStore()
        )
        let pasteboard = NSPasteboard(
            name: .init("dev.bybee.AnyDoor.monitor.\(UUID().uuidString)")
        )
        writeMonitorPasteboard(
            pasteboard,
            text: "baseline",
            declaredSource: "dev.bybee.baseline"
        )
        var requestedGenerations: [Int] = []
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            snapshotRequest: { pasteboard, generation in
                requestedGenerations.append(generation)
                return ClipboardHistoryPasteboardCaptureRequest(
                    pasteboard: pasteboard,
                    expectedGeneration: generation
                )
            },
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        let unstableItem = NSPasteboardItem()
        unstableItem.setString(
            "dev.bybee.overwritten",
            forType: .init("org.nspasteboard.source")
        )
        let provider = MonitorChangingPasteboardDataProvider(
            replacementText: "latest stable",
            replacementSource: "dev.bybee.latest"
        )
        unstableItem.setDataProvider(provider, forTypes: [.string])
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([unstableItem]))
        let overwrittenGeneration = pasteboard.changeCount
        await monitor.observeForTesting()

        let page = try await module.page(.init())
        XCTAssertEqual(provider.callCount, 1)
        XCTAssertEqual(
            requestedGenerations,
            [overwrittenGeneration, pasteboard.changeCount]
        )
        let entry = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(entry.previewText, "latest stable")
        XCTAssertEqual(
            entry.source.bundleIdentifier,
            "dev.bybee.latest"
        )
    }

    @MainActor
    func testGenerationJumpCapturesOnlyLatestAndRecordsOverwrittenCount()
        async throws
    {
        let fixture = try MonitorTemporaryStore()
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.url,
            keyStore: MonitorMemoryKeyStore()
        )
        let pasteboard = NSPasteboard(
            name: .init("dev.bybee.AnyDoor.monitor.\(UUID().uuidString)")
        )
        writeMonitorPasteboard(
            pasteboard,
            text: "baseline",
            declaredSource: "dev.bybee.baseline"
        )
        let instrumentation = ClipboardHistoryMonitorInstrumentation()
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            instrumentation: instrumentation,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        writeMonitorPasteboard(
            pasteboard,
            text: "overwritten before observation",
            declaredSource: "dev.bybee.intermediate"
        )
        writeMonitorPasteboard(
            pasteboard,
            text: "latest stable",
            declaredSource: "dev.bybee.latest"
        )
        await monitor.observeForTesting()

        let page = try await module.page(.init())
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.entries.first?.previewText, "latest stable")
        XCTAssertEqual(
            instrumentation.snapshot(),
            ClipboardHistoryMonitorMetrics(
                keyHintCount: 0,
                idleTimerFireCount: 0,
                boostedTimerFireCount: 0,
                observedChangeCount: 1,
                capturedChangeCount: 1,
                overwrittenGenerationCount: 1
            )
        )
    }

    @MainActor
    private func writeMonitorPasteboard(
        _ pasteboard: NSPasteboard,
        text: String,
        declaredSource: String
    ) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(
            declaredSource,
            forType: .init("org.nspasteboard.source")
        )
    }
}

private final class MonitorChangingPasteboardDataProvider: NSObject,
    NSPasteboardItemDataProvider
{
    nonisolated(unsafe) private(set) var callCount = 0
    private let replacementText: String
    private let replacementSource: String

    init(replacementText: String, replacementSource: String) {
        self.replacementText = replacementText
        self.replacementSource = replacementSource
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard let pasteboard else { return }
        callCount += 1
        pasteboard.clearContents()
        pasteboard.setString(replacementText, forType: .string)
        pasteboard.setString(
            replacementSource,
            forType: .init("org.nspasteboard.source")
        )
        item.setString("overwritten during snapshot", forType: type)
    }
}

private final class MonitorTemporaryStore {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnyDoor-ClipboardMonitor-\(UUID().uuidString)",
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
}

@MainActor
private final class MonitorTestClock {
    var now = Duration.zero
}

private struct MonitorMemoryKeyStore: ClipboardHistoryMasterKeyStoring {
    private static let key = Data(repeating: 0x83, count: 32)

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
