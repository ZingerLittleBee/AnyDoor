/// Tracks nested system prompts that must temporarily disable Spotlight-style
/// auto-dismiss. The caller owns the actual AppKit monitors; this type only says
/// when to disarm or rearm them.
struct AutoDismissSuspension {
    enum EndResult: Equatable {
        case alreadyIdle
        case stillSuspended
        case readyToRearm
    }

    private(set) var depth = 0

    var isActive: Bool { depth > 0 }

    /// Returns true only for the first active suspension, so the caller can disarm
    /// monitors once even when prompts nest.
    mutating func begin() -> Bool {
        depth += 1
        return depth == 1
    }

    /// Returns `.readyToRearm` only when the final active suspension ends. A stale
    /// end after `reset()` is explicitly ignored.
    mutating func end() -> EndResult {
        guard depth > 0 else { return .alreadyIdle }
        depth -= 1
        return depth == 0 ? .readyToRearm : .stillSuspended
    }

    mutating func reset() {
        depth = 0
    }
}
