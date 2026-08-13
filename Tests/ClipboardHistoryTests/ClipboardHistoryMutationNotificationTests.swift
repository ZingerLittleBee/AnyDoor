import AppKit
import Foundation
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryMutationNotificationTests: XCTestCase {
    func testConfirmedEmptyClearDoesNotPublishMutation() async throws {
        let fixture = try MutationNotificationStore()
        let center = NotificationCenter()
        let recorder = ClipboardHistoryMutationRecorder(center: center)
        let module = fixture.makeModule(notificationCenter: center)

        let preview = try await module.previewClearHistory(
            scope: .includingProtected
        )
        XCTAssertEqual(preview.affectedCount, 0)
        let outcome = try await module.confirm(preview.token)
        XCTAssertEqual(
            outcome,
            .applied(deletedCount: 0)
        )
        XCTAssertEqual(recorder.count, 0)
    }

    func testCaptureAndApplyPublishOnlyCommittedChanges() async throws {
        let fixture = try MutationNotificationStore()
        let center = NotificationCenter()
        let recorder = ClipboardHistoryMutationRecorder(center: center)
        let failureSwitch = MutationFailureSwitch()
        let module = fixture.makeModule(
            faultInjector: ClipboardHistoryFaultInjector { point in
                point == .databaseTransaction && failureSwitch.isEnabled
            },
            notificationCenter: center
        )

        let captured = try await module.capture(
            textRequest("captured")
        )
        XCTAssertEqual(recorder.count, 1)

        let pasteboardRequest = await MainActor.run {
            let pasteboard = NSPasteboard(
                name: .init(
                    "dev.bybee.AnyDoor.mutation.\(UUID().uuidString)"
                )
            )
            pasteboard.clearContents()
            return ClipboardHistoryPasteboardCaptureRequest(
                pasteboard: pasteboard
            )
        }
        let skipped = try await module.capture(
            pasteboardRequest,
            source: .unknown
        )
        XCTAssertEqual(skipped, .skipped(.empty))
        XCTAssertEqual(recorder.count, 1)

        let missing = ClipboardHistoryEntryID(UUID())
        let missingOutcome = try await module.apply(.delete(missing))
        XCTAssertEqual(
            missingOutcome,
            .notFound
        )
        XCTAssertEqual(recorder.count, 1)

        _ = try await module.apply(
            .setFavorite(captured.entryID, true)
        )
        XCTAssertEqual(recorder.count, 2)

        _ = try await module.apply(
            .setFavorite(captured.entryID, true)
        )
        _ = try await module.apply(.setTags(captured.entryID, []))
        XCTAssertEqual(recorder.count, 2)

        failureSwitch.isEnabled = true
        do {
            _ = try await module.apply(
                .editText(captured.entryID, "replacement")
            )
            XCTFail("Expected the committed mutation to fail")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .storageFailure
            )
        }
        XCTAssertEqual(recorder.count, 2)
    }

    func testTagAndRetentionPublicationSkipsNoOpsAndStaleConfirmation()
        async throws
    {
        let fixture = try MutationNotificationStore()
        let center = NotificationCenter()
        let recorder = ClipboardHistoryMutationRecorder(center: center)
        let clock = MutationTestClock(
            Date(timeIntervalSince1970: 1_800_000_000)
        )
        let module = fixture.makeModule(
            clock: clock,
            notificationCenter: center
        )
        let captured = try await module.capture(textRequest("tagged"))
        recorder.reset()

        let assignment = try await module.createTagDefinition(
            named: "Work",
            assigningTo: captured.entryID
        )
        XCTAssertEqual(recorder.count, 1)

        _ = try await module.createTagDefinition(
            named: "Work",
            assigningTo: captured.entryID
        )
        _ = try await module.renameTagDefinition(
            id: assignment.definition.id,
            to: "Work"
        )
        _ = try await module.replaceTagDefinitions(
            with: [assignment.definition]
        )
        _ = try await module.deleteTagDefinition(id: "missing")
        XCTAssertEqual(recorder.count, 1)

        _ = try await module.renameTagDefinition(
            id: assignment.definition.id,
            to: "Projects"
        )
        XCTAssertEqual(recorder.count, 2)
        let importedDefinition = ClipboardHistoryTagDefinition(
            id: assignment.definition.id,
            displayName: "Imported"
        )
        _ = try await module.replaceTagDefinitions(
            with: [importedDefinition]
        )
        _ = try await module.replaceTagDefinitions(
            with: [importedDefinition]
        )
        XCTAssertEqual(recorder.count, 3)

        let samePeriod = try await module.prepareRetentionChange(
            to: .thirtyDays
        )
        XCTAssertEqual(samePeriod, .applied(.thirtyDays))
        XCTAssertEqual(recorder.count, 3)

        let directChange = try await module.prepareRetentionChange(
            to: .unlimited
        )
        XCTAssertEqual(directChange, .applied(.unlimited))
        XCTAssertEqual(recorder.count, 4)

        _ = try await module.capture(textRequest("old"))
        recorder.reset()
        clock.now = clock.now.addingTimeInterval(2 * 86_400)
        _ = try await module.prepareRetentionChange(to: .thirtyDays)
        recorder.reset()
        guard case .confirmationRequired(let preview) =
            try await module.prepareRetentionChange(to: .oneDay)
        else {
            return XCTFail("Expected a destructive retention preview")
        }
        XCTAssertEqual(recorder.count, 0)

        _ = try await module.capture(textRequest("new revision"))
        recorder.reset()
        guard case .stale = try await module.confirm(preview.token) else {
            return XCTFail("Expected the confirmation to become stale")
        }
        XCTAssertEqual(recorder.count, 0)

        guard case .confirmationRequired(let refreshed) =
            try await module.prepareRetentionChange(to: .oneDay)
        else {
            return XCTFail("Expected a refreshed retention preview")
        }
        let confirmed = try await module.confirm(refreshed.token)
        XCTAssertEqual(
            confirmed,
            .applied(deletedCount: 1)
        )
        XCTAssertEqual(recorder.count, 1)
    }

    private func textRequest(
        _ text: String
    ) -> ClipboardHistoryCaptureRequest {
        ClipboardHistoryCaptureRequest(
            source: .unknown,
            content: .text(text)
        )
    }
}

final class ClipboardHistoryMutationRecorder: @unchecked Sendable {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var value = 0
    private var observer: NSObjectProtocol?

    var count: Int {
        lock.withLock { value }
    }

    init(center: NotificationCenter) {
        self.center = center
        observer = center.addObserver(
            forName: .clipboardHistoryV2DidMutate,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                self.value += 1
            }
        }
    }

    deinit {
        if let observer {
            center.removeObserver(observer)
        }
    }

    func reset() {
        lock.withLock { value = 0 }
    }
}

private final class MutationNotificationStore {
    let root: URL
    private let keyStore = MutationNotificationKeyStore()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnyDoor-ClipboardMutationNotification-\(UUID().uuidString)"
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeModule(
        clock: MutationTestClock = MutationTestClock(Date()),
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector(),
        notificationCenter: NotificationCenter
    ) -> ClipboardHistoryModule {
        ClipboardHistoryModule(
            testingStoreRoot: root,
            keyStore: keyStore,
            faultInjector: faultInjector,
            now: { clock.now },
            notificationCenter: notificationCenter
        )
    }
}

private struct MutationNotificationKeyStore:
    ClipboardHistoryMasterKeyStoring
{
    private static let key = Data(repeating: 0x8A, count: 32)

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

private final class MutationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    init(_ now: Date) {
        value = now
    }
}

private final class MutationFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isEnabled: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
