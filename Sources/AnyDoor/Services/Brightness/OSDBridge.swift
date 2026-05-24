import Foundation
import CoreGraphics
import ObjectiveC
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "osd.bridge")

/// Triggers macOS's native chiclet brightness OSD via the private
/// `OSDManager.sharedManager()` API resident in `OSD.framework`.
///
/// Best-effort: every failure path silently no-ops. DDC writes still
/// take effect on the display regardless of whether the OSD shows.
///
/// Implementation note: we resolve `+sharedManager` and the chiclet
/// selector at runtime via `class_getMethodImplementation` and call
/// them through `unsafeBitCast`'d C function pointers, avoiding the
/// long-deprecated `NSInvocation` bridging dance.
enum OSDBridge {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/OSD.framework/OSD"

    /// `OSDGraphic.brightness` — the chiclet image identifier used by
    /// the system brightness HUD.
    private static let brightnessImageID: Int64 = 1
    private static let totalChiclets: UInt32 = 16
    private static let msecUntilFade: UInt32 = 1500
    private static let priority: UInt32 = 0x0

    /// `dlopen` the private framework once. `nonisolated(unsafe)` is
    /// safe here: `dlopen` is thread-safe and the handle is only ever
    /// read, never reassigned.
    nonisolated(unsafe) private static let loadedHandle: UnsafeMutableRawPointer? = {
        dlopen(frameworkPath, RTLD_LAZY)
    }()

    /// `showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:`
    /// Primitive args only — no NSObjects to bridge.
    private typealias ShowImageIMP = @convention(c) (
        AnyObject, Selector,
        Int64,        // imageID
        UInt32,       // displayID
        UInt32,       // priority
        UInt32,       // msecUntilFade
        UInt32,       // filledChiclets
        UInt32,       // totalChiclets
        ObjCBool      // locked
    ) -> Void

    private typealias SharedManagerIMP = @convention(c) (AnyClass, Selector) -> AnyObject?

    static func showBrightness(_ value: Float, on displayID: CGDirectDisplayID) {
        guard loadedHandle != nil else {
            logger.debug("OSD.framework not loaded; skipping OSD")
            return
        }
        guard let managerClass = NSClassFromString("OSDManager") else {
            logger.debug("OSDManager class not found; skipping OSD")
            return
        }
        // +sharedManager is a class method, so look it up on the metaclass.
        let sharedSel = NSSelectorFromString("sharedManager")
        guard let metaclass = object_getClass(managerClass),
              let sharedIMP = class_getMethodImplementation(metaclass, sharedSel) else {
            logger.debug("OSDManager +sharedManager IMP not found; skipping OSD")
            return
        }
        let sharedFn = unsafeBitCast(sharedIMP, to: SharedManagerIMP.self)
        guard let manager = sharedFn(managerClass, sharedSel) else {
            logger.debug("OSDManager.sharedManager returned nil; skipping OSD")
            return
        }

        let showSel = NSSelectorFromString(
            "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
        )
        guard let showIMP = class_getMethodImplementation(managerClass, showSel) else {
            logger.debug("OSDManager chiclet IMP not found; skipping OSD")
            return
        }
        // Sanity check: confirm the instance actually responds. If a future
        // macOS renames this selector, bail silently rather than calling a
        // garbage IMP returned from the forwarding machinery.
        if let manager = manager as? NSObject, !manager.responds(to: showSel) {
            logger.debug("OSDManager does not respond to chiclet selector; skipping OSD")
            return
        }
        let showFn = unsafeBitCast(showIMP, to: ShowImageIMP.self)
        let clamped = max(0, min(1, value))
        let filled = UInt32((clamped * Float(totalChiclets)).rounded())

        showFn(
            manager,
            showSel,
            brightnessImageID,
            UInt32(displayID),
            priority,
            msecUntilFade,
            filled,
            totalChiclets,
            ObjCBool(false)
        )
    }
}
