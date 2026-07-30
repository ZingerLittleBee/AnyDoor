import AppKit
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryDerivedIndexingTests: XCTestCase {
    func testProductionVisionRecognizesRepresentativeTextAndNoTextFixtures()
        async throws
    {
        let recognizer = ClipboardHistoryVisionRecognizer()

        let text = try await recognizer.recognize(
            .ocr,
            in: [try visionFixture(named: "representative-text")]
        )
        let noText = try await recognizer.recognize(
            .ocr,
            in: [try visionFixture(named: "no-text")]
        )

        let recognizedText = text.joined(separator: " ").uppercased()
        XCTAssertTrue(recognizedText.contains("ANYDOOR"))
        XCTAssertTrue(recognizedText.contains("4827"))
        XCTAssertEqual(noText, [])
    }

    func testProductionVisionRecognizesSingleMultiAndNoQRFixtures()
        async throws
    {
        let recognizer = ClipboardHistoryVisionRecognizer()

        let single = try await recognizer.recognize(
            .qr,
            in: [try visionFixture(named: "single-qr")]
        )
        let multiple = try await recognizer.recognize(
            .qr,
            in: [try visionFixture(named: "multi-qr")]
        )
        let none = try await recognizer.recognize(
            .qr,
            in: [try visionFixture(named: "no-qr")]
        )

        XCTAssertEqual(single, ["anydoor://fixture/single"])
        XCTAssertEqual(
            Set(multiple),
            [
                "anydoor://fixture/alpha",
                "anydoor://fixture/beta",
            ]
        )
        XCTAssertEqual(multiple.count, 2)
        XCTAssertEqual(none, [])
    }

    func testOCRDefaultsOffAndEnablingOnlyAffectsLaterOwnedBitmapCaptures()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = DeterministicVisionRecognizer(
            results: [
                .ocr: ["https://derived.example OCR"],
                .qr: [
                    "anydoor://derived/qr/one",
                    "anydoor://derived/qr/two",
                ],
            ]
        )
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: recognizer
        )

        let first = try await module.capture(
            bitmapRequest(try makeBitmap(color: .systemRed))
        )
        await module.awaitDerivedJobsForTesting()
        let firstJobKinds = try await module.derivedJobKindsForTesting(
            first.entryID
        )
        XCTAssertEqual(
            firstJobKinds,
            [.qr]
        )

        try await module.setAutomaticImageTextIndexingEnabled(true)
        let firstJobKindsAfterEnabling =
            try await module.derivedJobKindsForTesting(first.entryID)
        XCTAssertEqual(
            firstJobKindsAfterEnabling,
            [.qr],
            "Enabling must not backfill an earlier bitmap"
        )

        let second = try await module.capture(
            bitmapRequest(try makeBitmap(color: .systemBlue))
        )
        await module.awaitDerivedJobsForTesting()

        let secondJobKinds = try await module.derivedJobKindsForTesting(
            second.entryID
        )
        XCTAssertEqual(
            secondJobKinds,
            [.ocr, .qr]
        )
        let qrValues = try await module.derivedSearchValuesForTesting(
            second.entryID,
            kind: .qr
        )
        XCTAssertEqual(
            qrValues,
            [
                "anydoor://derived/qr/one",
                "anydoor://derived/qr/two",
            ]
        )
        let ocrSearch = try await module.page(
            ClipboardHistoryQuery(text: "derived.example")
        )
        XCTAssertEqual(
            ocrSearch.entries.map(\.id),
            [second.entryID]
        )
        let linkPage = try await module.page(
            ClipboardHistoryQuery(facet: .link)
        )
        XCTAssertEqual(
            linkPage.entries,
            [],
            "OCR text must not recursively add content facets"
        )
        let textPage = try await module.page(
            ClipboardHistoryQuery(facet: .text)
        )
        XCTAssertEqual(
            textPage.entries,
            [],
            "Derived OCR text is searchable but is not a content facet"
        )
        let qrPage = try await module.page(
            ClipboardHistoryQuery(facet: .qrCode)
        )
        XCTAssertEqual(
            qrPage.entries.map(\.id),
            [second.entryID, first.entryID]
        )
        let secondQRFacetCount = try await module.facetCountForTesting(
            second.entryID,
            facet: .qrCode
        )
        XCTAssertEqual(secondQRFacetCount, 1)
        let materialized = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: second.entryID,
                purpose: .normalPaste
            )
        )
        guard case .data(let typeIdentifier, let bitmap) =
            try XCTUnwrap(materialized.items.first?.representations.first)
        else {
            return XCTFail("Expected the original bitmap representation")
        }
        XCTAssertEqual(typeIdentifier, UTType.png.identifier)
        XCTAssertFalse(bitmap.isEmpty)
    }

    func testSuccessfulEmptyQRRecognitionCompletesWithoutRetryOrFacet()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = CountingVisionRecognizer(results: [.qr: []])
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: recognizer
        )

        let capture = try await module.capture(
            bitmapRequest(try makeBitmap(color: .systemGreen))
        )
        await module.awaitDerivedJobsForTesting()

        let qrCallCount = await recognizer.callCount(for: .qr)
        XCTAssertEqual(qrCallCount, 1)
        let job = try await module.derivedJobForTesting(
            capture.entryID,
            kind: .qr
        )
        XCTAssertEqual(job?.state, "succeeded")
        XCTAssertEqual(job?.attemptCount, 1)
        let qrPage = try await module.page(
            ClipboardHistoryQuery(facet: .qrCode)
        )
        XCTAssertEqual(qrPage.entries, [])
    }

    func testRecognitionFailureStopsSilentlyAfterExactlyThreeAttempts()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = FailingVisionRecognizer()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: recognizer
        )

        let capture = try await module.capture(
            bitmapRequest(try makeBitmap(color: .systemOrange))
        )
        await module.awaitDerivedJobsForTesting()

        let exhaustedCallCount = await recognizer.callCount(for: .qr)
        XCTAssertEqual(exhaustedCallCount, 3)
        let job = try await module.derivedJobForTesting(
            capture.entryID,
            kind: .qr
        )
        XCTAssertEqual(job?.state, "failed")
        XCTAssertEqual(job?.attemptCount, 3)
        await module.awaitDerivedJobsForTesting()
        let finalCallCount = await recognizer.callCount(for: .qr)
        XCTAssertEqual(finalCallCount, 3)
    }

    func testDuplicateRecaptureRefreshesOnlyCurrentlyEligibleBudgets()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = CountingVisionRecognizer(
            results: [.ocr: [], .qr: []]
        )
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: recognizer
        )
        let bitmap = try makeBitmap(color: .systemPurple)

        let first = try await module.capture(bitmapRequest(bitmap))
        await module.awaitDerivedJobsForTesting()
        let second = try await module.capture(bitmapRequest(bitmap))
        await module.awaitDerivedJobsForTesting()
        XCTAssertEqual(second.entryID, first.entryID)
        let disabledQR = try await module.derivedJobForTesting(
            first.entryID,
            kind: .qr
        )
        let disabledOCR = try await module.derivedJobForTesting(
            first.entryID,
            kind: .ocr
        )
        XCTAssertEqual(
            disabledQR?.eligibleGeneration,
            2
        )
        XCTAssertNil(disabledOCR)

        try await module.setAutomaticImageTextIndexingEnabled(true)
        _ = try await module.capture(bitmapRequest(bitmap))
        await module.awaitDerivedJobsForTesting()
        let enabledQR = try await module.derivedJobForTesting(
            first.entryID,
            kind: .qr
        )
        let enabledOCR = try await module.derivedJobForTesting(
            first.entryID,
            kind: .ocr
        )
        XCTAssertEqual(
            enabledQR?.eligibleGeneration,
            3
        )
        XCTAssertEqual(
            enabledOCR?.eligibleGeneration,
            1
        )

        try await module.setAutomaticImageTextIndexingEnabled(false)
        _ = try await module.capture(bitmapRequest(bitmap))
        await module.awaitDerivedJobsForTesting()
        let reDisabledQR = try await module.derivedJobForTesting(
            first.entryID,
            kind: .qr
        )
        let reDisabledOCR = try await module.derivedJobForTesting(
            first.entryID,
            kind: .ocr
        )
        XCTAssertEqual(
            reDisabledQR?.eligibleGeneration,
            4
        )
        XCTAssertEqual(
            reDisabledOCR?.eligibleGeneration,
            1,
            "Disabling must leave the completed OCR generation and text intact"
        )
    }

    func testDuplicateGenerationRejectsLateResultBeforePublishingFreshResult()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = RecaptureVisionRecognizer()
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: recognizer
        )
        let bitmap = try makeBitmap(color: .systemPurple)
        let first = try await module.capture(bitmapRequest(bitmap))
        await recognizer.waitUntilFirstCallStarts()

        let duplicate = try await module.capture(bitmapRequest(bitmap))
        XCTAssertEqual(duplicate.entryID, first.entryID)
        await recognizer.releaseFirstCall()
        await module.awaitDerivedJobsForTesting()

        let stale = try await module.page(
            ClipboardHistoryQuery(text: "stale generation")
        )
        let fresh = try await module.page(
            ClipboardHistoryQuery(text: "fresh generation")
        )
        XCTAssertEqual(stale.entries, [])
        XCTAssertEqual(fresh.entries.map(\.id), [first.entryID])
        let job = try await module.derivedJobForTesting(
            first.entryID,
            kind: .qr
        )
        XCTAssertEqual(job?.eligibleGeneration, 2)
        XCTAssertEqual(job?.attemptCount, 1)
    }

    func testDisablingDoesNotCancelAlreadyEligibleOCRWork() async throws {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = GatedVisionRecognizer(
            blockedKind: .ocr,
            results: [
                .ocr: ["pending OCR survives disable"],
                .qr: [],
            ]
        )
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: recognizer
        )
        try await module.setAutomaticImageTextIndexingEnabled(true)
        let capture = try await module.capture(
            bitmapRequest(try makeBitmap(color: .systemYellow))
        )
        await recognizer.waitUntilStarted(.ocr)

        try await module.setAutomaticImageTextIndexingEnabled(false)
        await recognizer.release(.ocr)
        await module.awaitDerivedJobsForTesting()

        let page = try await module.page(
            ClipboardHistoryQuery(text: "survives disable")
        )
        XCTAssertEqual(page.entries.map(\.id), [capture.entryID])
        let setting = try await module.isAutomaticImageTextIndexingEnabled()
        XCTAssertFalse(setting)
    }

    func testPendingJobResumesAfterStoreReopen() async throws {
        let fixture = try DerivedIndexingTemporaryStore()
        let blocking = GatedVisionRecognizer(
            blockedKind: .qr,
            results: [.qr: ["stale result"]]
        )
        let first = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: blocking
        )
        let capture = try await first.capture(
            bitmapRequest(try makeBitmap(color: .systemBrown))
        )
        await blocking.waitUntilStarted(.qr)
        let close = Task {
            try await first.closeStoreForTesting()
        }
        await blocking.waitUntilCancelled(.qr)
        await blocking.release(.qr)
        try await close.value

        let resumedRecognizer = CountingVisionRecognizer(
            results: [.qr: ["resumed QR value"]]
        )
        let reopened = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: resumedRecognizer
        )
        await reopened.awaitDerivedJobsForTesting()

        let resumedCallCount = await resumedRecognizer.callCount(for: .qr)
        XCTAssertEqual(resumedCallCount, 1)
        let page = try await reopened.page(
            ClipboardHistoryQuery(text: "resumed QR")
        )
        XCTAssertEqual(page.entries.map(\.id), [capture.entryID])
    }

    func testDeletionCancelsRecognitionAndLateResultCannotResurrectData()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = GatedVisionRecognizer(
            blockedKind: .qr,
            results: [.qr: ["late QR value"]]
        )
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: recognizer
        )
        let capture = try await module.capture(
            bitmapRequest(try makeBitmap(color: .systemCyan))
        )
        await recognizer.waitUntilStarted(.qr)

        let deletion = try await module.apply(.delete(capture.entryID))
        XCTAssertEqual(deletion, .deleted)
        await recognizer.release(.qr)
        await module.awaitDerivedJobsForTesting()

        let page = try await module.page(
            ClipboardHistoryQuery(text: "late QR")
        )
        XCTAssertEqual(page.entries, [])
        let deletedJob = try await module.derivedJobForTesting(
            capture.entryID,
            kind: .qr
        )
        XCTAssertNil(deletedJob)
        let deletedValues = try await module.derivedSearchValuesForTesting(
            capture.entryID,
            kind: .qr
        )
        XCTAssertEqual(
            deletedValues,
            []
        )
    }

    func testDerivedPublicationRollsBackFieldsBothFTSAndFacetTogether()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = CountingVisionRecognizer(
            results: [.qr: ["transactional QR"]]
        )
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            faultInjector: ClipboardHistoryFaultInjector(
                points: [.searchInsertAfterField]
            ),
            visionRecognizer: recognizer
        )

        let capture = try await module.capture(
            bitmapRequest(try makeBitmap(color: .systemMint))
        )
        await module.awaitDerivedJobsForTesting()

        let job = try await module.derivedJobForTesting(
            capture.entryID,
            kind: .qr
        )
        XCTAssertEqual(job?.state, "failed")
        XCTAssertEqual(job?.attemptCount, 3)
        let derivedValues = try await module.derivedSearchValuesForTesting(
            capture.entryID,
            kind: .qr
        )
        XCTAssertEqual(
            derivedValues,
            []
        )
        let qrPage = try await module.page(
            ClipboardHistoryQuery(facet: .qrCode)
        )
        XCTAssertEqual(qrPage.entries, [])
        let indexesAreConsistent =
            try await module.searchIndexesAreConsistentForTesting()
        XCTAssertTrue(indexesAreConsistent)
    }

    func testExplicitQRTextUsesProvenanceWithoutBitmapAutoIndexing()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = CountingVisionRecognizer(results: [:])
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: recognizer
        )

        let capture = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: .unknown,
                content: .qrCode("anydoor://explicit/scanner")
            )
        )
        await module.awaitDerivedJobsForTesting()

        let callCount = await recognizer.totalCallCount()
        XCTAssertEqual(callCount, 0)
        let jobKinds = try await module.derivedJobKindsForTesting(
            capture.entryID
        )
        XCTAssertEqual(
            jobKinds,
            []
        )
        let qrPage = try await module.page(
            ClipboardHistoryQuery(facet: .qrCode)
        )
        XCTAssertEqual(qrPage.entries.map(\.id), [capture.entryID])
        let searchPage = try await module.page(
            ClipboardHistoryQuery(text: "explicit/scanner")
        )
        XCTAssertEqual(searchPage.entries.map(\.id), [capture.entryID])
    }

    func testPersistedOCRSettingDoesNotCreateJobsForPreexistingBitmap()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let firstRecognizer = CountingVisionRecognizer(results: [.qr: []])
        let first = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: firstRecognizer
        )
        let capture = try await first.capture(
            bitmapRequest(try makeBitmap(color: .lightGray))
        )
        await first.awaitDerivedJobsForTesting()
        try await first.setAutomaticImageTextIndexingEnabled(true)
        try await first.removeDerivedJobsForTesting(capture.entryID)
        try await first.closeStoreForTesting()

        let reopenedRecognizer = CountingVisionRecognizer(results: [:])
        let reopened = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: reopenedRecognizer
        )
        await reopened.awaitDerivedJobsForTesting()

        let persistedSetting =
            try await reopened.isAutomaticImageTextIndexingEnabled()
        XCTAssertTrue(persistedSetting)
        let reopenedCallCount = await reopenedRecognizer.totalCallCount()
        XCTAssertEqual(reopenedCallCount, 0)
        let reopenedJobKinds =
            try await reopened.derivedJobKindsForTesting(capture.entryID)
        XCTAssertEqual(
            reopenedJobKinds,
            []
        )
    }

    @MainActor
    func testReferencedImageFileIsNeverSentToVision() async throws {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = CountingVisionRecognizer(results: [:])
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: recognizer
        )
        try await module.setAutomaticImageTextIndexingEnabled(true)
        let imageURL = fixture.directory.appendingPathComponent("reference.png")
        try makeBitmap(color: .systemIndigo).write(to: imageURL)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "dev.bybee.AnyDoor.derived-file.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(imageURL.absoluteString, forType: .fileURL)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let outcome = try await module.capture(
            ClipboardHistoryPasteboardCaptureRequest(pasteboard: pasteboard),
            source: .unknown
        )
        guard case .captured(let capture) = outcome else {
            return XCTFail("Expected the referenced image to be captured")
        }
        await module.awaitDerivedJobsForTesting()

        let calls = await recognizer.totalCallCount()
        XCTAssertEqual(calls, 0)
        let jobs = try await module.derivedJobKindsForTesting(capture.entryID)
        XCTAssertEqual(jobs, [])
        let imagePage = try await module.page(
            ClipboardHistoryQuery(facet: .image)
        )
        let filePage = try await module.page(
            ClipboardHistoryQuery(facet: .file)
        )
        XCTAssertEqual(imagePage.entries.map(\.id), [capture.entryID])
        XCTAssertEqual(filePage.entries.map(\.id), [capture.entryID])
    }

    func testClearHistoryCancelsRecognitionAndRejectsLatePublication()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = GatedVisionRecognizer(
            blockedKind: .qr,
            results: [.qr: ["late clear value"]]
        )
        let module = try ClipboardHistoryModule(
            testingDatabaseURL: fixture.databaseURL,
            databaseKey: fixture.databaseKey,
            visionRecognizer: recognizer
        )
        let capture = try await module.capture(
            bitmapRequest(try makeBitmap(color: .systemPink))
        )
        await recognizer.waitUntilStarted(.qr)
        let preview = try await module.previewClearHistory(
            scope: .unprotectedOnly
        )

        let clear = try await module.confirm(preview.token)
        XCTAssertEqual(clear, .applied(deletedCount: 1))
        await recognizer.release(.qr)
        await module.awaitDerivedJobsForTesting()

        let values = try await module.derivedSearchValuesForTesting(
            capture.entryID,
            kind: .qr
        )
        XCTAssertEqual(values, [])
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries, [])
    }

    func testExpiryCancelsRecognitionAndRejectsLatePublication()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let clock = DerivedIndexingClock(
            Date(timeIntervalSince1970: 10_000)
        )
        let recognizer = GatedVisionRecognizer(
            blockedKind: .qr,
            results: [.qr: ["late expiry value"]]
        )
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.directory,
            keyStore: DerivedIndexingMasterKeyStore(),
            now: { clock.now },
            visionRecognizer: recognizer
        )
        let capture = try await module.capture(
            bitmapRequest(try makeBitmap(color: .systemTeal))
        )
        await recognizer.waitUntilStarted(.qr)
        clock.now = clock.now.addingTimeInterval(31 * 86_400)

        _ = try await module.performMaintenance(orphanGracePeriod: 0)
        await recognizer.release(.qr)
        await module.awaitDerivedJobsForTesting()

        let values = try await module.derivedSearchValuesForTesting(
            capture.entryID,
            kind: .qr
        )
        XCTAssertEqual(values, [])
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries, [])
    }

    func testRetryCancelsThenResumesPendingRecognition() async throws {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = GatedVisionRecognizer(
            blockedKind: .qr,
            results: [.qr: ["retry resumed value"]]
        )
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.directory,
            keyStore: DerivedIndexingMasterKeyStore(),
            visionRecognizer: recognizer
        )
        let capture = try await module.capture(
            bitmapRequest(try makeBitmap(color: .systemGray))
        )
        await recognizer.waitUntilStarted(.qr)

        let retry = Task {
            await module.retry()
        }
        await recognizer.waitUntilCancelled(.qr)
        await recognizer.release(.qr)
        await retry.value
        await module.awaitDerivedJobsForTesting()

        let page = try await module.page(
            ClipboardHistoryQuery(text: "retry resumed")
        )
        XCTAssertEqual(page.entries.map(\.id), [capture.entryID])
    }

    func testResetCancelsRecognitionAndStartsWithNoDerivedState()
        async throws
    {
        let fixture = try DerivedIndexingTemporaryStore()
        let recognizer = GatedVisionRecognizer(
            blockedKind: .qr,
            results: [.qr: ["reset stale value"]]
        )
        let module = ClipboardHistoryModule(
            testingStoreRoot: fixture.directory,
            keyStore: DerivedIndexingMasterKeyStore(),
            visionRecognizer: recognizer
        )
        _ = try await module.capture(
            bitmapRequest(try makeBitmap(color: .darkGray))
        )
        await recognizer.waitUntilStarted(.qr)

        let reset = Task {
            try await module.reset(confirmation: .confirmed)
        }
        await recognizer.waitUntilCancelled(.qr)
        await recognizer.release(.qr)
        try await reset.value
        await module.awaitDerivedJobsForTesting()

        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries, [])
        let setting = try await module.isAutomaticImageTextIndexingEnabled()
        XCTAssertFalse(setting)
    }
}

private func visionFixture(named name: String) throws -> Data {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "png")
    )
    return try Data(contentsOf: url)
}

private actor DeterministicVisionRecognizer:
    ClipboardHistoryVisionRecognizing
{
    private let results: [ClipboardHistoryDerivedJobKind: [String]]

    init(results: [ClipboardHistoryDerivedJobKind: [String]]) {
        self.results = results
    }

    func recognize(
        _ kind: ClipboardHistoryDerivedJobKind,
        in bitmaps: [Data]
    ) async throws -> [String] {
        XCTAssertFalse(bitmaps.isEmpty)
        return results[kind] ?? []
    }
}

private actor CountingVisionRecognizer: ClipboardHistoryVisionRecognizing {
    private let results: [ClipboardHistoryDerivedJobKind: [String]]
    private var counts: [ClipboardHistoryDerivedJobKind: Int] = [:]

    init(results: [ClipboardHistoryDerivedJobKind: [String]]) {
        self.results = results
    }

    func recognize(
        _ kind: ClipboardHistoryDerivedJobKind,
        in bitmaps: [Data]
    ) async throws -> [String] {
        XCTAssertFalse(bitmaps.isEmpty)
        counts[kind, default: 0] += 1
        return results[kind] ?? []
    }

    func callCount(for kind: ClipboardHistoryDerivedJobKind) -> Int {
        counts[kind, default: 0]
    }

    func totalCallCount() -> Int {
        counts.values.reduce(0, +)
    }
}

private actor FailingVisionRecognizer: ClipboardHistoryVisionRecognizing {
    private var counts: [ClipboardHistoryDerivedJobKind: Int] = [:]

    func recognize(
        _ kind: ClipboardHistoryDerivedJobKind,
        in bitmaps: [Data]
    ) async throws -> [String] {
        XCTAssertFalse(bitmaps.isEmpty)
        counts[kind, default: 0] += 1
        throw DerivedIndexingTestError.recognitionFailed
    }

    func callCount(for kind: ClipboardHistoryDerivedJobKind) -> Int {
        counts[kind, default: 0]
    }
}

private actor GatedVisionRecognizer: ClipboardHistoryVisionRecognizing {
    private let blockedKind: ClipboardHistoryDerivedJobKind
    private let results: [ClipboardHistoryDerivedJobKind: [String]]
    private var startedKinds: Set<ClipboardHistoryDerivedJobKind> = []
    private var startWaiters:
        [ClipboardHistoryDerivedJobKind: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters:
        [ClipboardHistoryDerivedJobKind: CheckedContinuation<Void, Never>] = [:]
    private var releasedKinds: Set<ClipboardHistoryDerivedJobKind> = []
    private var cancelledKinds: Set<ClipboardHistoryDerivedJobKind> = []
    private var cancellationWaiters:
        [ClipboardHistoryDerivedJobKind: [CheckedContinuation<Void, Never>]] = [:]

    init(
        blockedKind: ClipboardHistoryDerivedJobKind,
        results: [ClipboardHistoryDerivedJobKind: [String]]
    ) {
        self.blockedKind = blockedKind
        self.results = results
    }

    func recognize(
        _ kind: ClipboardHistoryDerivedJobKind,
        in bitmaps: [Data]
    ) async throws -> [String] {
        XCTAssertFalse(bitmaps.isEmpty)
        startedKinds.insert(kind)
        for waiter in startWaiters.removeValue(forKey: kind) ?? [] {
            waiter.resume()
        }
        if kind == blockedKind, !releasedKinds.contains(kind) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    releaseWaiters[kind] = continuation
                }
            } onCancel: {
                Task {
                    await self.recordCancellation(of: kind)
                }
            }
        }
        return results[kind] ?? []
    }

    func waitUntilStarted(_ kind: ClipboardHistoryDerivedJobKind) async {
        guard !startedKinds.contains(kind) else { return }
        await withCheckedContinuation { continuation in
            startWaiters[kind, default: []].append(continuation)
        }
    }

    func release(_ kind: ClipboardHistoryDerivedJobKind) {
        releasedKinds.insert(kind)
        releaseWaiters.removeValue(forKey: kind)?.resume()
    }

    func waitUntilCancelled(_ kind: ClipboardHistoryDerivedJobKind) async {
        guard !cancelledKinds.contains(kind) else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[kind, default: []].append(continuation)
        }
    }

    private func recordCancellation(
        of kind: ClipboardHistoryDerivedJobKind
    ) {
        cancelledKinds.insert(kind)
        for waiter in cancellationWaiters.removeValue(forKey: kind) ?? [] {
            waiter.resume()
        }
    }
}

private actor RecaptureVisionRecognizer:
    ClipboardHistoryVisionRecognizing
{
    private var callCount = 0
    private var firstCallStarted = false
    private var firstCallStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCallRelease: CheckedContinuation<Void, Never>?

    func recognize(
        _ kind: ClipboardHistoryDerivedJobKind,
        in bitmaps: [Data]
    ) async throws -> [String] {
        XCTAssertEqual(kind, .qr)
        XCTAssertFalse(bitmaps.isEmpty)
        callCount += 1
        if callCount == 1 {
            firstCallStarted = true
            for waiter in firstCallStartWaiters {
                waiter.resume()
            }
            firstCallStartWaiters = []
            await withCheckedContinuation { continuation in
                firstCallRelease = continuation
            }
            return ["stale generation value"]
        }
        return ["fresh generation value"]
    }

    func waitUntilFirstCallStarts() async {
        guard !firstCallStarted else { return }
        await withCheckedContinuation { continuation in
            firstCallStartWaiters.append(continuation)
        }
    }

    func releaseFirstCall() {
        firstCallRelease?.resume()
        firstCallRelease = nil
    }
}

private enum DerivedIndexingTestError: Error {
    case recognitionFailed
}

private final class DerivedIndexingMasterKeyStore:
    ClipboardHistoryMasterKeyStoring,
    @unchecked Sendable
{
    private let key = Data(repeating: 0x87, count: 32)

    func load() -> ClipboardHistoryMasterKeyResult {
        .key(key)
    }

    func create() -> ClipboardHistoryMasterKeyResult {
        .key(key)
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        .missing
    }
}

private final class DerivedIndexingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

private final class DerivedIndexingTemporaryStore {
    let directory: URL
    let databaseURL: URL
    let databaseKey = Data(repeating: 0x86, count: 32)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnyDoor-DerivedIndexingTests-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        databaseURL = directory.appendingPathComponent("history.sqlite")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func bitmapRequest(_ data: Data) -> ClipboardHistoryCaptureRequest {
    ClipboardHistoryCaptureRequest(
        source: .unknown,
        content: .bitmap(data, provenance: .image)
    )
}

private func makeBitmap(color: NSColor) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 64,
        pixelsHigh: 64,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw ClipboardHistoryModuleError.storageFailure
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    color.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 64, height: 64)).fill()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw ClipboardHistoryModuleError.storageFailure
    }
    return data
}

extension ClipboardHistoryModule {
    struct DerivedJobForTesting: Equatable {
        let state: String
        let attemptCount: Int
        let eligibleGeneration: Int
    }

    func derivedJobKindsForTesting(
        _ entryID: ClipboardHistoryEntryID
    ) throws -> Set<ClipboardHistoryDerivedJobKind> {
        let database = try requiredDatabase()
        return try database.read { database in
            Set(
                try String.fetchAll(
                    database,
                    sql: """
                        SELECT kind
                        FROM clipboard_derived_jobs
                        WHERE entry_id = ?
                        ORDER BY kind
                        """,
                    arguments: [
                        entryID.value.uuidString.lowercased()
                    ]
                ).compactMap(ClipboardHistoryDerivedJobKind.init(rawValue:))
            )
        }
    }

    func derivedJobForTesting(
        _ entryID: ClipboardHistoryEntryID,
        kind: ClipboardHistoryDerivedJobKind
    ) throws -> DerivedJobForTesting? {
        let database = try requiredDatabase()
        return try database.read { database in
            try Row.fetchOne(
                database,
                sql: """
                    SELECT state, attempt_count, eligible_generation
                    FROM clipboard_derived_jobs
                    WHERE entry_id = ? AND kind = ?
                    """,
                arguments: [
                    entryID.value.uuidString.lowercased(),
                    kind.rawValue,
                ]
            ).map {
                DerivedJobForTesting(
                    state: $0["state"],
                    attemptCount: $0["attempt_count"],
                    eligibleGeneration: $0["eligible_generation"]
                )
            }
        }
    }

    func derivedSearchValuesForTesting(
        _ entryID: ClipboardHistoryEntryID,
        kind: ClipboardHistoryDerivedJobKind
    ) throws -> [String] {
        let database = try requiredDatabase()
        return try database.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT value
                    FROM clipboard_search_fields
                    WHERE entry_id = ? AND field_kind = ?
                    ORDER BY field_index
                    """,
                arguments: [
                    entryID.value.uuidString.lowercased(),
                    kind.rawValue,
                ]
            )
        }
    }

    func removeDerivedJobsForTesting(
        _ entryID: ClipboardHistoryEntryID
    ) throws {
        let database = try requiredDatabase()
        try database.write { database in
            try database.execute(
                sql: """
                    DELETE FROM clipboard_derived_jobs
                    WHERE entry_id = ?
                    """,
                arguments: [
                    entryID.value.uuidString.lowercased()
                ]
            )
        }
    }

    func searchIndexesAreConsistentForTesting() throws -> Bool {
        let database = try requiredDatabase()
        return try database.write {
            try Self.searchIndexesPassIntegrityCheck(in: $0)
        }
    }

    func facetCountForTesting(
        _ entryID: ClipboardHistoryEntryID,
        facet: ClipboardHistoryFacet
    ) throws -> Int {
        let database = try requiredDatabase()
        return try database.read {
            try Int.fetchOne(
                $0,
                sql: """
                    SELECT COUNT(*)
                    FROM clipboard_entry_facets
                    WHERE entry_id = ? AND facet = ?
                    """,
                arguments: [
                    entryID.value.uuidString.lowercased(),
                    facet.rawValue,
                ]
            ) ?? 0
        }
    }
}
