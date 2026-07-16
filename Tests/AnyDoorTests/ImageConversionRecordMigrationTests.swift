import SwiftData
import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

/// Proves that `ImageConversionRecord`'s Target Size extension migrates safely.
/// SwiftData lightweight migration only backfills scalar/optional-scalar columns
/// from inline defaults, so a legacy row written before the extension must fault
/// under the new schema and read back its old values plus every new default.
///
/// A unit test cannot host two schema versions of one `@Model` class at once, so
/// the fixture is built on disk: a record is written and the container is closed,
/// then a fresh container reopens the same store URL and faults the row. This is
/// the on-disk path the design requires — an in-memory store cannot prove it.
final class ImageConversionRecordMigrationTests: XCTestCase {
    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyDoorImageConvMigration-\(UUID().uuidString).store")
    }

    override func tearDown() {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
        }
        storeURL = nil
        super.tearDown()
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: ImageConversionRecord.self,
            configurations: ModelConfiguration(url: storeURL)
        )
    }

    /// A record written using only the pre-extension init faults under the new
    /// schema with its old values intact and every new field at its inline default.
    func testLegacyRecordFaultsWithNewDefaults() throws {
        do {
            let container = try makeContainer()
            let context = ModelContext(container)
            let record = ImageConversionRecord(
                sourceName: "Legacy.png",
                sourceKind: .file,
                targetFormat: .jpeg,
                qualityPercent: 85,
                outputPath: "/tmp/legacy.jpg",
                createdAt: Date(timeIntervalSinceReferenceDate: 100)
            )
            context.insert(record)
            try context.save()
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<ImageConversionRecord>())
        let row = try XCTUnwrap(rows.first)

        // Old values survive.
        XCTAssertEqual(row.sourceName, "Legacy.png")
        XCTAssertEqual(row.sourceKind, ImageConversionSourceKind.file.rawValue)
        XCTAssertEqual(row.targetFormat, ImageConversionFormat.jpeg.rawValue)
        XCTAssertEqual(row.qualityPercent, 85)
        XCTAssertEqual(row.outputPath, "/tmp/legacy.jpg")
        XCTAssertEqual(row.createdAt, Date(timeIntervalSinceReferenceDate: 100))

        // Every new field backfilled to its inline default.
        XCTAssertEqual(row.modeRaw, "quality")
        XCTAssertEqual(row.outcomeRaw, "qualityCompleted")
        XCTAssertNil(row.targetByteCount)
        XCTAssertNil(row.sourceByteCount)
        XCTAssertNil(row.outputByteCount)
        XCTAssertNil(row.sourcePixelWidth)
        XCTAssertNil(row.sourcePixelHeight)
        XCTAssertNil(row.outputPixelWidth)
        XCTAssertNil(row.outputPixelHeight)
        XCTAssertFalse(row.resizeFallbackApplied)
        XCTAssertNil(row.displayDowngradeRaw)
        XCTAssertFalse(row.firstFrameOnly)

        // Typed accessors resolve the defaults.
        XCTAssertEqual(row.mode, .quality)
        XCTAssertEqual(row.outcome, .qualityCompleted)
    }

    /// A Target Size record carrying byte counts, pixel dims, resize flag, and an
    /// HDR-to-SDR downgrade round-trips exactly across a store close/reopen.
    func testTargetReachedRecordRoundTrips() throws {
        do {
            let container = try makeContainer()
            let context = ModelContext(container)
            let record = ImageConversionRecord(
                sourceName: "Photo.heic",
                sourceKind: .file,
                targetFormat: .jpeg,
                qualityPercent: 0,
                outputPath: "/tmp/photo.jpg",
                createdAt: Date(timeIntervalSinceReferenceDate: 200)
            )
            record.modeRaw = ImageConversionMode.targetSize.rawValue
            record.outcomeRaw = ImageConversionOutcome.targetReached.rawValue
            record.targetByteCount = 1_000_000
            record.sourceByteCount = 4_200_000
            record.outputByteCount = 987_654
            record.sourcePixelWidth = 4032
            record.sourcePixelHeight = 3024
            record.outputPixelWidth = 2016
            record.outputPixelHeight = 1512
            record.resizeFallbackApplied = true
            record.displayDowngradeRaw = "hdrToSDR"
            context.insert(record)
            try context.save()
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<ImageConversionRecord>()).first)

        XCTAssertEqual(row.qualityPercent, 0)
        XCTAssertEqual(row.modeRaw, "targetSize")
        XCTAssertEqual(row.mode, .targetSize)
        XCTAssertEqual(row.outcome, .targetReached)
        XCTAssertEqual(row.targetByteCount, 1_000_000)
        XCTAssertEqual(row.sourceByteCount, 4_200_000)
        XCTAssertEqual(row.outputByteCount, 987_654)
        XCTAssertEqual(row.sourcePixelWidth, 4032)
        XCTAssertEqual(row.sourcePixelHeight, 3024)
        XCTAssertEqual(row.outputPixelWidth, 2016)
        XCTAssertEqual(row.outputPixelHeight, 1512)
        XCTAssertTrue(row.resizeFallbackApplied)
        XCTAssertEqual(row.displayDowngradeRaw, "hdrToSDR")
        XCTAssertFalse(row.firstFrameOnly)
    }

    /// A target miss saved anyway records `targetUnattainable`.
    func testTargetUnattainableRecordRoundTrips() throws {
        do {
            let container = try makeContainer()
            let context = ModelContext(container)
            let record = ImageConversionRecord(
                sourceName: "Huge.png",
                sourceKind: .file,
                targetFormat: .jpeg,
                qualityPercent: 0,
                outputPath: "/tmp/huge.jpg"
            )
            record.modeRaw = ImageConversionMode.targetSize.rawValue
            record.outcomeRaw = ImageConversionOutcome.targetUnattainable.rawValue
            record.targetByteCount = 50_000
            record.outputByteCount = 320_000
            context.insert(record)
            try context.save()
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<ImageConversionRecord>()).first)

        XCTAssertEqual(row.mode, .targetSize)
        XCTAssertEqual(row.outcome, .targetUnattainable)
        XCTAssertEqual(row.targetByteCount, 50_000)
        XCTAssertEqual(row.outputByteCount, 320_000)
    }

    /// A Quality-mode first-frame-only conversion persists that fact.
    func testFirstFrameOnlyRecordRoundTrips() throws {
        do {
            let container = try makeContainer()
            let context = ModelContext(container)
            let record = ImageConversionRecord(
                sourceName: "Animation.gif",
                sourceKind: .file,
                targetFormat: .png,
                qualityPercent: 100,
                outputPath: "/tmp/animation.png"
            )
            record.firstFrameOnly = true
            context.insert(record)
            try context.save()
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<ImageConversionRecord>()).first)

        XCTAssertTrue(row.firstFrameOnly)
        XCTAssertEqual(row.mode, .quality)
        XCTAssertEqual(row.outcome, .qualityCompleted)
    }

    /// An unknown `outcomeRaw` falls back to `.qualityCompleted` rather than
    /// trapping, so an imported garbage value never leaves the UI unbound.
    func testUnknownOutcomeRawFallsBack() throws {
        do {
            let container = try makeContainer()
            let context = ModelContext(container)
            let record = ImageConversionRecord(
                sourceName: "Weird.jpg",
                sourceKind: .file,
                targetFormat: .jpeg,
                qualityPercent: 50,
                outputPath: "/tmp/weird.jpg"
            )
            record.outcomeRaw = "someFutureOutcome"
            record.modeRaw = "someFutureMode"
            context.insert(record)
            try context.save()
        }

        let container = try makeContainer()
        let context = ModelContext(container)
        let row = try XCTUnwrap(try context.fetch(FetchDescriptor<ImageConversionRecord>()).first)

        XCTAssertEqual(row.outcomeRaw, "someFutureOutcome")
        XCTAssertEqual(row.outcome, .qualityCompleted)
        XCTAssertEqual(row.mode, .quality)
    }
}
