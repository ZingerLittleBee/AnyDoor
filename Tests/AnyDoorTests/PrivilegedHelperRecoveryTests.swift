import XCTest
import PluginInterface
import ServiceManagement
@testable import AnyDoor

@MainActor
final class PrivilegedHelperRecoveryTests: XCTestCase {
    private actor Helper {
        var outdated: Bool
        let probeError: String?
        let recoveryError: String?
        let writeError: String?
        let staysOutdated: Bool
        var events: [String] = []
        var written: [String] = []

        init(outdated: Bool = true, probeError: String? = nil, recoveryError: String? = nil,
             writeError: String? = nil, staysOutdated: Bool = false) {
            self.outdated = outdated
            self.probeError = probeError
            self.recoveryError = recoveryError
            self.writeError = writeError
            self.staysOutdated = staysOutdated
        }

        func validate() throws {
            events.append("validate")
            if let probeError { throw PrivilegedHelperCallError(message: probeError) }
            if outdated { throw PrivilegedHelperCallError(message: "helper_outdated") }
        }

        func recover() throws {
            events.append("recover")
            if let recoveryError { throw PrivilegedHelperCallError(message: recoveryError) }
            outdated = staysOutdated
        }

        func write(_ content: String, _ baseline: String) throws {
            events.append("write")
            if let writeError { throw PrivilegedHelperCallError(message: writeError) }
            written = [content, baseline]
        }
    }

    private func write(using helper: Helper) async throws {
        try await PrivilegedHelperCall.writeHosts(
            "new hosts", replacing: "original hosts",
            validateVersion: { try await helper.validate() },
            recover: { try await helper.recover() },
            write: { try await helper.write($0, $1) }
        )
    }

    func testOutdatedHelperRecoversBeforeConditionalWrite() async throws {
        let helper = Helper()
        try await write(using: helper)
        let events = await helper.events
        let written = await helper.written
        XCTAssertEqual(events, ["validate", "recover", "validate", "write"])
        XCTAssertEqual(written, ["new hosts", "original hosts"])
    }

    func testCurrentHelperWritesWithoutRestarting() async throws {
        let helper = Helper(outdated: false)
        try await write(using: helper)
        let events = await helper.events
        XCTAssertEqual(events, ["validate", "write"])
    }

    func testConnectionFailureDoesNotChangeServiceRegistration() async {
        let helper = Helper(probeError: "connection interrupted")
        await assertFailure(helper, message: "connection interrupted", events: ["validate"])
    }

    func testFailedRecoveryNeverWrites() async {
        let helper = Helper(recoveryError: "helper_approval_required")
        await assertFailure(helper, message: "helper_approval_required", events: ["validate", "recover"])
    }

    func testStillOutdatedHelperIsNotRetriedAgain() async {
        let helper = Helper(staysOutdated: true)
        await assertFailure(helper, message: "helper_outdated", events: ["validate", "recover", "validate"])
    }

    func testChangedBaselineAfterRecoveryIsNotRetried() async {
        let helper = Helper(writeError: "hosts_changed")
        await assertFailure(helper, message: "hosts_changed", events: ["validate", "recover", "validate", "write"])
    }

    func testWriteFailureDoesNotTriggerRecovery() async {
        let helper = Helper(outdated: false, writeError: "helper_outdated")
        await assertFailure(helper, message: "helper_outdated", events: ["validate", "write"])
    }

    func testCancellationAfterRecoveryDoesNotWrite() async throws {
        let helper = Helper()
        let operation = Task {
            try await PrivilegedHelperCall.writeHosts(
                "new hosts", replacing: "original hosts",
                validateVersion: { try await helper.validate() },
                recover: {
                    try await helper.recover()
                    withUnsafeCurrentTask { $0?.cancel() }
                },
                write: { try await helper.write($0, $1) }
            )
        }
        do {
            try await operation.value
            XCTFail("A cancelled write must not reach the helper")
        } catch is CancellationError {
            let written = await helper.written
            XCTAssertTrue(written.isEmpty)
        }
    }

    func testConcurrentRecoveryWaitsForUnregistrationAndRestoresAfterCancellation() async throws {
        let entered = expectation(description: "unregistration started")
        let joined = expectation(description: "second caller joined")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        var events: [String] = []
        let recovery = PrivilegedHelperRecovery(
            validateVersion: {
                events.append("validate")
                throw PrivilegedHelperCallError(message: "helper_outdated")
            },
            unregister: {
                events.append("unregister")
                entered.fulfill()
                for await _ in gate.stream { break }
                events.append("unregistered")
            },
            register: { events.append("register") }
        )
        let first = Task { try await recovery.recover() }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task {
            joined.fulfill()
            try await recovery.recover()
        }
        await fulfillment(of: [joined], timeout: 2)
        XCTAssertTrue(recovery.isRecovering)
        XCTAssertEqual(events, ["validate", "unregister"])
        first.cancel()
        gate.continuation.yield(())
        try await first.value
        try await second.value
        XCTAssertEqual(events, ["validate", "unregister", "unregistered", "register"])
        XCTAssertFalse(recovery.isRecovering)
    }

    func testRecoveryRechecksBeforeRestartingAnAlreadyUpdatedHelper() async throws {
        let recovery = PrivilegedHelperRecovery(
            validateVersion: {},
            unregister: { XCTFail("A compatible helper must not be unregistered") },
            register: { XCTFail("A compatible helper must not be registered again") }
        )
        try await recovery.recover()
        XCTAssertFalse(recovery.isRecovering)
    }

    func testUnregistrationFailureDoesNotRegisterAndClearsRecoveryState() async {
        let recovery = PrivilegedHelperRecovery(
            validateVersion: { throw PrivilegedHelperCallError(message: "helper_outdated") },
            unregister: { throw PrivilegedHelperCallError(message: "unregister failed") },
            register: { XCTFail("Must wait for successful unregistration") }
        )
        do {
            try await recovery.recover()
            XCTFail("Expected unregistration failure")
        } catch {
            XCTAssertEqual((error as? PrivilegedHelperCallError)?.message, "unregister failed")
        }
        XCTAssertFalse(recovery.isRecovering)
    }

    func testTransientRegistrationFailureRestoresSharedDaemon() async throws {
        var registered = true
        var attempts = 0
        var unregisterCount = 0
        let recovery = PrivilegedHelperRecovery(
            validateVersion: { throw PrivilegedHelperCallError(message: "helper_outdated") },
            unregister: {
                registered = false
                unregisterCount += 1
            },
            register: {
                attempts += 1
                if attempts == 1 {
                    throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
                }
                registered = true
            },
            sleep: { _ in }
        )
        try await recovery.recover()
        XCTAssertTrue(registered)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(unregisterCount, 1)
    }

    func testLaterConsumerRestoresRegistrationAfterRetryExhaustion() async throws {
        var registered = true
        let failure = RegistrationFailure()
        var unregisterCount = 0
        var attempts = 0
        var delays: [Duration] = []
        let recovery = PrivilegedHelperRecovery(
            validateVersion: { throw PrivilegedHelperCallError(message: "helper_outdated") },
            unregister: {
                registered = false
                unregisterCount += 1
            },
            register: {
                attempts += 1
                if failure.isActive {
                    throw NSError(domain: "SMAppServiceErrorDomain", code: 1)
                }
                registered = true
            },
            sleep: { delays.append($0) }
        )
        do {
            try await recovery.recover()
            XCTFail("Expected registration failure")
        } catch {
            XCTAssertFalse(registered)
        }
        XCTAssertEqual(attempts, 4)
        XCTAssertEqual(delays, [.milliseconds(500), .seconds(1), .seconds(2)])
        XCTAssertTrue(recovery.needsRegistration)
        XCTAssertFalse(recovery.isRecovering)
        failure.isActive = false
        // This is the entry point used before forced Scheduled Shutdown.
        try await recovery.waitForRecovery()
        XCTAssertTrue(registered, "The later consumer must not continue without the shared daemon")
        XCTAssertEqual(attempts, 5)
        XCTAssertFalse(recovery.needsRegistration)
        XCTAssertEqual(unregisterCount, 1, "Retry registration without unregistering an absent daemon")
    }

    func testConcurrentConsumersShareRegistrationRetryDespiteCallerCancellation() async throws {
        let entered = expectation(description: "registration retry started")
        let joined = expectation(description: "another consumer joined recovery")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        var attempts = 0
        var unregisterCount = 0
        let recovery = PrivilegedHelperRecovery(
            validateVersion: { throw PrivilegedHelperCallError(message: "helper_outdated") },
            unregister: { unregisterCount += 1 },
            register: {
                attempts += 1
                if attempts == 1 { throw NSError(domain: "SMAppServiceErrorDomain", code: 1) }
            },
            sleep: { _ in
                entered.fulfill()
                for await _ in gate.stream { break }
            }
        )
        let first = Task { try await recovery.recover() }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task {
            joined.fulfill()
            try await recovery.waitForRecovery()
        }
        await fulfillment(of: [joined], timeout: 2)
        first.cancel()
        XCTAssertTrue(recovery.needsRegistration)
        XCTAssertEqual(attempts, 1)
        gate.continuation.yield(())
        try await first.value
        try await second.value
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(unregisterCount, 1)
        XCTAssertFalse(recovery.needsRegistration)
    }

    func testExplicitReleasePreventsLaterConsumerFromRestoringRegistration() async throws {
        var attempts = 0
        let recovery = PrivilegedHelperRecovery(
            validateVersion: { throw PrivilegedHelperCallError(message: "helper_outdated") },
            unregister: {},
            register: {
                attempts += 1
                throw PrivilegedHelperCallError(message: "helper_approval_required")
            },
            sleep: { _ in XCTFail("Approval errors must not be retried") }
        )
        do {
            try await recovery.recover()
            XCTFail("Expected approval failure")
        } catch {
            XCTAssertEqual((error as? PrivilegedHelperCallError)?.message, "helper_approval_required")
        }
        XCTAssertTrue(recovery.needsRegistration)
        recovery.registrationWasRemoved()
        try await recovery.waitForRecovery()
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(recovery.needsRegistration)
    }

    func testRegistrationRetryPolicyRejectsPermanentAndUnrelatedErrors() {
        for code in [Int(EPERM), kSMErrorInternalFailure, kSMErrorServiceUnavailable] {
            XCTAssertTrue(PrivilegedHelperRecovery.canRetryRegistration(
                NSError(domain: "SMAppServiceErrorDomain", code: code)
            ))
        }
        for code in [kSMErrorInvalidSignature, kSMErrorAuthorizationFailure,
                     kSMErrorToolNotValid, kSMErrorLaunchDeniedByUser, kSMErrorAlreadyRegistered] {
            XCTAssertFalse(PrivilegedHelperRecovery.canRetryRegistration(
                NSError(domain: "SMAppServiceErrorDomain", code: code)
            ))
        }
        XCTAssertFalse(PrivilegedHelperRecovery.canRetryRegistration(NSError(domain: NSPOSIXErrorDomain, code: 1)))
        XCTAssertFalse(PrivilegedHelperRecovery.canRetryRegistration(
            PrivilegedHelperCallError(message: "helper_approval_required")
        ))
    }

    private final class RegistrationFailure {
        var isActive = true
    }

    private func assertFailure(_ helper: Helper, message: String, events: [String]) async {
        do {
            try await write(using: helper)
            XCTFail("Expected \(message)")
        } catch {
            XCTAssertEqual((error as? PrivilegedHelperCallError)?.message, message)
        }
        let actualEvents = await helper.events
        let written = await helper.written
        XCTAssertEqual(actualEvents, events)
        XCTAssertTrue(written.isEmpty)
    }
}
