import XCTest
import SwiftData
import PluginInterface
@testable import AnyDoor

/// A fresh `PanelStore` over an in-memory container holding a
/// `BuiltinPreference` row for each of `rows`, so a test never touches
/// `PanelStore.shared` or the seeder's defaults. Notices go to `presentToast`
/// instead of the toast window.
@MainActor
func makePanelLaneTestStore(
    rows: [BuiltinItem],
    providers: [any BuiltinProvider] = [],
    presentToast: @escaping @MainActor (ToastStyle) -> Void = { _ in }
) throws -> PanelStore {
    let container = try ModelContainer(
        for: KeyBinding.self, BuiltinPreference.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    for item in rows {
        container.mainContext.insert(BuiltinPreference(itemKey: item.rawValue))
    }
    try container.mainContext.save()
    let store = PanelStore(presentToast: presentToast)
    store.bootstrap(modelContainer: container, providers: providers)
    return store
}

/// An action whose `run()` throws `error`, or succeeds when it is nil.
private actor FailingActionProvider: ActionProvider {
    let itemKey: BuiltinItem
    private let error: (any Error)?
    private(set) var runCount = 0

    init(_ itemKey: BuiltinItem, throwing error: (any Error)?) {
        self.itemKey = itemKey
        self.error = error
    }

    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        runCount += 1
        if let error { throw error }
    }
}

/// A switch whose read or write throws as scripted. A failure can also change
/// the permission it reports, as Dark Mode caches `.denied` after -1743.
private actor FailingToggleProvider: ToggleProvider {
    let itemKey: BuiltinItem
    private var isOn: Bool
    private let readError: (any Error)?
    private let writeError: (any Error)?
    private var currentPermission: PermissionStatus
    private let permissionAfterFailure: PermissionStatus?

    init(
        _ itemKey: BuiltinItem,
        isOn: Bool = false,
        readError: (any Error)? = nil,
        writeError: (any Error)? = nil,
        permission: PermissionStatus = .notRequired,
        permissionAfterFailure: PermissionStatus? = nil
    ) {
        self.itemKey = itemKey
        self.isOn = isOn
        self.readError = readError
        self.writeError = writeError
        self.currentPermission = permission
        self.permissionAfterFailure = permissionAfterFailure
    }

    var permission: PermissionStatus { currentPermission }

    func readState() async throws -> Bool {
        if let readError { try fail(with: readError) }
        return isOn
    }

    func setState(_ enabled: Bool) async throws {
        if let writeError { try fail(with: writeError) }
        isOn = enabled
    }

    private func fail(with error: any Error) throws {
        if let permissionAfterFailure { currentPermission = permissionAfterFailure }
        throw error
    }
}

/// The message of the only notice in `toasts`, failing the test unless there
/// is exactly one and it is a failure (`ToastStyle` is not Equatable).
private func onlyFailureMessage(
    in toasts: [ToastStyle],
    file: StaticString = #filePath,
    line: UInt = #line
) -> String? {
    guard toasts.count == 1, case .failure(let message) = toasts.first else {
        XCTFail("expected exactly one failure notice, got \(toasts.map(\.message))", file: file, line: line)
        return nil
    }
    return message
}

@MainActor
private func row(_ item: BuiltinItem, in store: PanelStore) -> PanelEntry? {
    store.topLevelEntries.first { $0.source == .builtin(item) }
}

/// A command whose provider throws reaches `PanelStore`, which logs it and
/// shows exactly one failure notice naming the command. The fakes throw
/// immediately: nothing here sleeps, runs a tool, sends Apple Events, or
/// opens the real toast window.
final class CommandFailureNoticeTests: XCTestCase {

    // MARK: - Actions

    @MainActor
    func testFailedActionShowsOneNoticeNamingTheAction() async throws {
        var toasts: [ToastStyle] = []
        let provider = FailingActionProvider(
            .flushDNS,
            throwing: BuiltinError.shellFailed(code: 1, output: "dscacheutil: failed")
        )
        let store = try makePanelLaneTestStore(
            rows: [.flushDNS], providers: [provider], presentToast: { toasts.append($0) }
        )

        await store.run(.flushDNS)

        XCTAssertEqual(onlyFailureMessage(in: toasts), L(.toastCommandFailed, L(.builtinFlushDNS)))
    }

    @MainActor
    func testActionThatSucceedsShowsNoNotice() async throws {
        var toasts: [ToastStyle] = []
        let provider = FailingActionProvider(.flushDNS, throwing: nil)
        let store = try makePanelLaneTestStore(
            rows: [.flushDNS], providers: [provider], presentToast: { toasts.append($0) }
        )

        await store.run(.flushDNS)

        let runCount = await provider.runCount
        XCTAssertEqual(runCount, 1)
        XCTAssertTrue(toasts.isEmpty, "a successful run reports nothing")
    }

    @MainActor
    func testCancellationAndADismissedScriptDialogShowNoNotice() async throws {
        var toasts: [ToastStyle] = []
        let cancelled = FailingActionProvider(.flushDNS, throwing: CancellationError())
        let dismissed = FailingActionProvider(
            .restartDock,
            throwing: BuiltinError.appleScriptFailed(code: -128, message: "User canceled.")
        )
        let store = try makePanelLaneTestStore(
            rows: [.flushDNS, .restartDock],
            providers: [cancelled, dismissed],
            presentToast: { toasts.append($0) }
        )

        await store.run(.flushDNS)
        await store.run(.restartDock)

        // Both ran, so the silence comes from the mapping, not a dropped run.
        let cancelledRuns = await cancelled.runCount
        let dismissedRuns = await dismissed.runCount
        XCTAssertEqual(cancelledRuns, 1)
        XCTAssertEqual(dismissedRuns, 1)
        XCTAssertTrue(toasts.isEmpty, "a cancel is not a failure: \(toasts.map(\.message))")
    }

    // MARK: - Toggles

    @MainActor
    func testFailedToggleKeepsItsStateAndShowsOneNotice() async throws {
        var toasts: [ToastStyle] = []
        let provider = FailingToggleProvider(
            .darkMode,
            isOn: true,
            writeError: BuiltinError.appleScriptFailed(code: -1712, message: "AppleEvent timed out.")
        )
        let store = try makePanelLaneTestStore(
            rows: [.darkMode], providers: [provider], presentToast: { toasts.append($0) }
        )
        await store.refreshAll()

        await store.toggle(.darkMode)

        XCTAssertEqual(onlyFailureMessage(in: toasts), L(.toastCommandToggleFailed, L(.builtinDarkMode)))
        XCTAssertEqual(row(.darkMode, in: store)?.toggleState, true, "a failed toggle keeps the row's last state")
    }

    @MainActor
    func testFailedReadDuringToggleShowsTheToggleNotice() async throws {
        var toasts: [ToastStyle] = []
        let provider = FailingToggleProvider(
            .hideDock,
            readError: BuiltinError.shellFailed(code: 1, output: "defaults: read failed")
        )
        let store = try makePanelLaneTestStore(
            rows: [.hideDock], providers: [provider], presentToast: { toasts.append($0) }
        )

        await store.toggle(.hideDock)

        XCTAssertEqual(onlyFailureMessage(in: toasts), L(.toastCommandToggleFailed, L(.builtinHideDock)))
    }

    @MainActor
    func testMissingAutomationPermissionAsksForAutomation() async throws {
        var toasts: [ToastStyle] = []
        let provider = FailingToggleProvider(
            .darkMode, writeError: BuiltinError.missingAutomationPermission
        )
        let store = try makePanelLaneTestStore(
            rows: [.darkMode], providers: [provider], presentToast: { toasts.append($0) }
        )

        await store.toggle(.darkMode)

        XCTAssertEqual(
            onlyFailureMessage(in: toasts),
            L(.toastCommandNeedsAutomation, L(.builtinDarkMode))
        )
    }

    @MainActor
    func testFailedToggleRefreshesTheRowPermission() async throws {
        let provider = FailingToggleProvider(
            .darkMode,
            writeError: BuiltinError.missingAutomationPermission,
            permission: .undetermined,
            permissionAfterFailure: .denied
        )
        let store = try makePanelLaneTestStore(rows: [.darkMode], providers: [provider])
        await store.refreshAll()
        XCTAssertEqual(row(.darkMode, in: store)?.permission, .undetermined)

        await store.toggle(.darkMode)

        // An open panel's row now asks for the permission instead of offering
        // the same failing switch again.
        XCTAssertEqual(row(.darkMode, in: store)?.permission, .denied)
    }

    @MainActor
    func testUnsupportedMicMuteShowsItsOwnMessageOnce() async throws {
        // Pins the mapping only. That the real MicrophoneMuteProvider no
        // longer shows this message itself takes an input device without a
        // settable mute, so only a manual check on hardware covers it.
        var toasts: [ToastStyle] = []
        let provider = FailingToggleProvider(
            .microphoneMute, writeError: BuiltinError.muteUnsupported
        )
        let store = try makePanelLaneTestStore(
            rows: [.microphoneMute], providers: [provider], presentToast: { toasts.append($0) }
        )

        await store.toggle(.microphoneMute)

        XCTAssertEqual(onlyFailureMessage(in: toasts), L(.toastMicMuteUnsupported))
    }

    @MainActor
    func testMuteUnsupportedOnAnotherCommandGetsTheGenericToggleNotice() async throws {
        // The dedicated message names the input device, so it must not reach
        // the output-device Mute row.
        var toasts: [ToastStyle] = []
        let provider = FailingToggleProvider(
            .muteAudio, writeError: BuiltinError.muteUnsupported
        )
        let store = try makePanelLaneTestStore(
            rows: [.muteAudio], providers: [provider], presentToast: { toasts.append($0) }
        )

        await store.toggle(.muteAudio)

        XCTAssertEqual(onlyFailureMessage(in: toasts), L(.toastCommandToggleFailed, L(.builtinMuteAudio)))
    }

    @MainActor
    func testKeepAwakeDurationFailureSaysFailedAndTogglePressSaysToggle() async throws {
        var toasts: [ToastStyle] = []
        let provider = KeepAwakeProvider(
            backend: ThrowingKeepAwakeBackend(failuresBeforeSuccess: 2)
        )
        let store = try makePanelLaneTestStore(
            rows: [.keepAwake], providers: [provider], presentToast: { toasts.append($0) }
        )

        // A duration preset, from the clock menu or the palette.
        await store.setKeepAwakeDuration(.minutes(15))
        XCTAssertEqual(onlyFailureMessage(in: toasts), L(.toastCommandFailed, L(.builtinKeepAwake)))

        // A switch press, from the row or a hotkey, goes through the same
        // duration path but names the attempt it came from.
        toasts.removeAll()
        await store.toggle(.keepAwake)
        XCTAssertEqual(onlyFailureMessage(in: toasts), L(.toastCommandToggleFailed, L(.builtinKeepAwake)))
        XCTAssertEqual(store.keepAwakeState, .off)
    }

    // MARK: - Passive refresh

    @MainActor
    func testRefreshShowsNoNoticeForAFailingRead() async throws {
        var toasts: [ToastStyle] = []
        let provider = FailingToggleProvider(
            .darkMode, readError: BuiltinError.missingAutomationPermission
        )
        let store = try makePanelLaneTestStore(
            rows: [.darkMode], providers: [provider], presentToast: { toasts.append($0) }
        )

        await store.refreshAll()

        XCTAssertTrue(toasts.isEmpty, "opening the panel asks for nothing, so it reports nothing")
    }

    // MARK: - Log summary

    func testLogSummaryKeepsCodesAndDropsOutput() {
        XCTAssertEqual(
            CommandFailure.logSummary(
                of: BuiltinError.shellFailed(code: 1, output: "/Users/someone/secret.txt")
            ),
            "BuiltinError.shellFailed(code: 1)"
        )
        XCTAssertEqual(
            CommandFailure.logSummary(
                of: BuiltinError.appleScriptFailed(
                    code: -1743, message: "Not authorized to send Apple events to System Events."
                )
            ),
            "BuiltinError.appleScriptFailed(code: -1743)"
        )
        // Errors from outside the provider contract keep only domain and code.
        XCTAssertEqual(
            CommandFailure.logSummary(of: SubprocessError.spawnFailed("/private/tmp/secret-tool")),
            "AnyDoor.SubprocessError 0"
        )
    }
}
