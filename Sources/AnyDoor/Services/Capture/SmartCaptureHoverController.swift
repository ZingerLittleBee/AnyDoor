import CoreGraphics
import Foundation

/// Coalesces pointer movement before resolving a smart-capture hierarchy. The
/// overlay owns its displayed selection; this controller only publishes fresh
/// resolutions and never clears or resets the user's chosen hierarchy level.
@MainActor
final class SmartCaptureHoverController {
    static let defaultThrottleInterval: Duration = .milliseconds(60)

    var onResolution: ((SmartCaptureResolution) -> Void)?

    private struct Request: Equatable, Sendable {
        let point: CGPoint
        let screenFrame: CGRect
        let windows: [CapturableWindow]
    }

    private let resolver: any SmartCaptureTargetResolving
    private let clock: any Clock<Duration>
    private let throttleInterval: Duration
    private var generation: UInt64 = 0
    private var lastRequest: Request?
    private var pendingRequest: Request?
    private var throttleTask: Task<Void, Never>?
    private var resolutionTask: Task<Void, Never>?

    init(
        resolver: any SmartCaptureTargetResolving,
        clock: any Clock<Duration> = ContinuousClock(),
        throttleInterval: Duration = .milliseconds(60)
    ) {
        precondition(throttleInterval > .zero)
        self.resolver = resolver
        self.clock = clock
        self.throttleInterval = throttleInterval
    }

    deinit {
        throttleTask?.cancel()
        resolutionTask?.cancel()
    }

    /// All geometry uses global CoreGraphics coordinates (top-left origin).
    /// Identical requests do not re-resolve or reset a Tab-selected hierarchy.
    func request(at point: CGPoint, screenFrame: CGRect, windows: [CapturableWindow]) {
        let request = Request(point: point, screenFrame: screenFrame, windows: windows)
        guard request != lastRequest else { return }

        // Invalidate at pointer-change time, not at the next throttled lookup:
        // a slow result must not briefly flash the old pointer's hierarchy.
        generation &+= 1
        lastRequest = request
        pendingRequest = request
        schedulePendingRequest()
    }

    /// Invalidates both the pending lookup and any eventual in-flight result.
    /// An uncooperative resolver remains tracked until it returns, so restarting
    /// cannot overlap it or enqueue another blocking AX call behind every move.
    func cancel() {
        generation &+= 1
        lastRequest = nil
        pendingRequest = nil
        throttleTask?.cancel()
        throttleTask = nil
        resolutionTask?.cancel()
    }

    private func schedulePendingRequest() {
        guard pendingRequest != nil, throttleTask == nil, resolutionTask == nil else { return }
        let clock = clock
        let interval = throttleInterval
        throttleTask = Task { @concurrent [weak self] in
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            await self?.startPendingResolution()
        }
    }

    private func startPendingResolution() {
        // A cancelled timer must not clear a newer timer's task handle after
        // cancel() followed immediately by a new request.
        guard !Task.isCancelled else { return }
        throttleTask = nil
        guard resolutionTask == nil, let request = pendingRequest else { return }
        pendingRequest = nil
        let requestGeneration = generation
        let resolver = resolver
        resolutionTask = Task { @concurrent [weak self] in
            let resolution = await resolver.resolve(
                at: request.point,
                screenFrame: request.screenFrame,
                windows: request.windows
            )
            await self?.didResolve(resolution, generation: requestGeneration)
        }
    }

    private func didResolve(_ resolution: SmartCaptureResolution, generation requestGeneration: UInt64) {
        resolutionTask = nil
        if !Task.isCancelled, requestGeneration == generation {
            onResolution?(resolution)
        }
        // Requests received during AX work occupy one slot. Wait one throttle
        // interval after completion, then resolve only that slot's latest value.
        schedulePendingRequest()
    }
}
