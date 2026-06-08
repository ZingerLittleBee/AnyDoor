import Foundation

/// User-selectable countdown presets for Scheduled Shutdown.
enum ScheduledShutdownDuration: Hashable, Sendable {
    case minutes(Int)

    /// Seconds until shutdown. Floored to one minute so a stray 0 never schedules
    /// an instant fire.
    var seconds: TimeInterval {
        switch self {
        case .minutes(let m): return TimeInterval(max(1, m)) * 60
        }
    }
}

/// Public state exposed to PanelStore. `.armed` carries the absolute target so
/// the panel can render "将于 HH:mm 关机" without polling.
enum ScheduledShutdownState: Hashable, Sendable {
    case off
    case armed(fireDate: Date)

    var isArmed: Bool {
        if case .armed = self { return true }
        return false
    }
}

/// Side-effect boundary for the actual shutdown so the service is testable
/// without powering off the machine.
protocol ShutdownExecuting: Sendable {
    func shutDown(forced: Bool) async throws
}

/// Boundary for the cancelable pre-fire warning UI so the service can be tested
/// without creating a real window.
@MainActor
protocol ShutdownWarningPresenting: AnyObject {
    func present(totalSeconds: Int, onCancel: @escaping @MainActor () -> Void)
    func update(secondsRemaining: Int)
    func dismiss()
}

/// Production executor. Graceful uses System Events (Automation permission only,
/// honors unsaved-work prompts). The forced branch (privileged helper) is wired
/// in a later task; until then both modes shut down gracefully.
struct SystemShutdownExecutor: ShutdownExecuting {
    func shutDown(forced: Bool) async throws {
        _ = try await AppleScriptRunner.run(
            "tell application \"System Events\" to shut down"
        )
    }
}
