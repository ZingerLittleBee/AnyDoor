import Foundation

/// A passive capture outcome the host surfaces as one non-modal notice.
///
/// Payload-free by design: a notice never carries content, sizes, paths, or
/// the source application, so presenting it cannot reveal what was refused.
/// The host owns the wording.
public enum ClipboardHistoryCaptureNotice: Hashable, Sendable {
    /// The observed change exceeded a Capture Safety Limit (canonical bytes or
    /// decoded pixels), so the complete entry was rejected.
    case tooLarge
    /// Capture threw, typically a failed history write, so the new entry was
    /// rejected while existing history and the pasteboard stay untouched.
    case captureFailed
}

/// Receives passive capture notices on the main actor, already rate limited.
public typealias ClipboardHistoryCaptureNoticeHandler =
    @MainActor @Sendable (ClipboardHistoryCaptureNotice) -> Void

extension ClipboardHistoryCaptureRejection {
    /// The notice a passive capture rejection raises, if any. Exhaustive on
    /// purpose: a new rejection reason must decide here whether the user hears
    /// about it.
    var captureNotice: ClipboardHistoryCaptureNotice? {
        switch self {
        case .contentTooLarge, .imageTooLarge:
            // One message covers both limits: the byte budget also counts
            // canonical image bytes, so "image" versus "content" would mislead.
            .tooLarge
        case .excluded:
            // A notice would reveal that an excluded app, such as a password
            // manager, just wrote to the pasteboard.
            nil
        case .empty, .unsupportedItem, .invalidFileReference:
            // Skipping is the designed behavior for these states, and they
            // are routine (cleared pasteboards, private types, deleted files).
            nil
        case .generationChanged:
            // An internal race the monitor retries.
            nil
        }
    }
}

/// Admits at most one notice of each kind per window on the monitor's
/// monotonic clock, so a burst of refused copies raises one notice rather than
/// a stream. Kinds are independent: a size notice never hides a capture
/// failure, and a failure never hides a size notice.
struct ClipboardHistoryCaptureNoticeLimiter {
    static let interval: Duration = .seconds(30)

    private var lastAdmitted: [ClipboardHistoryCaptureNotice: Duration] = [:]

    mutating func admit(
        _ notice: ClipboardHistoryCaptureNotice,
        at instant: Duration
    ) -> Bool {
        if let last = lastAdmitted[notice], instant - last < Self.interval {
            return false
        }
        lastAdmitted[notice] = instant
        return true
    }
}
