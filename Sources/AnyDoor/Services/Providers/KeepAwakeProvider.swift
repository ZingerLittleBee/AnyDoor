import IOKit.pwr_mgt
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "keepawake")

/// Prevents the system from going to sleep while the assertion is held.
///
/// Backed by IOPMAssertion (PreventUserIdleDisplaySleep). The assertion is held by this
/// actor's `assertionID` for the lifetime of the process or until `setState(false)` is called.
/// Process exit releases automatically — no cleanup required.
actor KeepAwakeProvider: ToggleProvider {
    let itemKey: BuiltinItem = .keepAwake

    var permission: PermissionStatus { .notRequired }

    private var assertionID: IOPMAssertionID?

    func readState() async throws -> Bool {
        assertionID != nil
    }

    func setState(_ enabled: Bool) async throws {
        if enabled {
            guard assertionID == nil else { return }
            var newID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "AnyDoor Keep Awake" as CFString,
                &newID
            )
            guard result == kIOReturnSuccess else {
                logger.error("IOPMAssertionCreateWithName failed: \(result)")
                throw BuiltinError.ioKitFailed(Int32(result))
            }
            assertionID = newID
        } else {
            guard let id = assertionID else { return }
            IOPMAssertionRelease(id)
            assertionID = nil
        }
    }
}
