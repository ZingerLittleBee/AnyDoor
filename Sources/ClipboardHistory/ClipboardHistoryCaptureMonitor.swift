import AppKit
import Foundation
import os

private let clipboardMonitorSignpostLog = OSLog(
    subsystem: "dev.bybee.AnyDoor",
    category: "ClipboardHistoryMonitor"
)

@MainActor
final class ClipboardHistoryCaptureMonitor {
    enum LifecycleEvent: Sendable {
        case willSleep
        case didWake
        case screenLocked
        case screenUnlocked
        case migrationStarted
        case migrationCompleted
    }

    private struct PendingCopyEventSource {
        let source: ClipboardHistoryApplicationSource
        let deadline: Duration
    }

    private let module: ClipboardHistoryModule
    private let pasteboard: NSPasteboard
    private let suppression: ClipboardHistorySelfWriteSuppression
    private let instrumentation: ClipboardHistoryMonitorInstrumentation
    private let sourceProvider:
        @MainActor () -> ClipboardHistoryApplicationSource?
    private let nowProvider: @MainActor () -> Duration
    private let snapshotRequest:
        @MainActor (NSPasteboard, Int) ->
            ClipboardHistoryPasteboardCaptureRequest
    private let policy = ClipboardHistoryObservationPolicy()

    private var configuration: ClipboardHistoryMonitoringConfiguration
    private var scheduler = ClipboardHistoryMonitorScheduler()
    private var lastGeneration: Int?
    private var pendingCopyEventSource: PendingCopyEventSource?
    private var observationInFlight = false
    private var observationRequested = false
    private var isEnabled = false
    private var isActive = false
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var eventHintSource: ClipboardHistoryCopyEventHintSource?
    private var scheduledTimerIsIdle = true
    private var lastOperationFailureReportAt: Duration?

    private static let operationFailureReportInterval: Duration = .seconds(30)

    init(
        module: ClipboardHistoryModule,
        pasteboard: NSPasteboard = .general,
        suppression: ClipboardHistorySelfWriteSuppression? = nil,
        instrumentation: ClipboardHistoryMonitorInstrumentation? = nil,
        configuration: ClipboardHistoryMonitoringConfiguration = .init(),
        sourceProvider: @escaping @MainActor
            () -> ClipboardHistoryApplicationSource? =
            ClipboardHistoryCaptureMonitor.frontmostApplicationSource,
        now: @escaping @MainActor () -> Duration =
            ClipboardHistoryCaptureMonitor.uptime,
        snapshotRequest: @escaping @MainActor (NSPasteboard, Int) ->
            ClipboardHistoryPasteboardCaptureRequest = {
                pasteboard,
                generation in
                ClipboardHistoryPasteboardCaptureRequest(
                    pasteboard: pasteboard,
                    expectedGeneration: generation
                )
            },
        installsSystemObservers: Bool = true
    ) {
        self.module = module
        self.pasteboard = pasteboard
        self.suppression = suppression ?? module.selfWriteSuppression
        self.instrumentation =
            instrumentation ?? module.monitorInstrumentation
        self.configuration = configuration
        self.sourceProvider = sourceProvider
        nowProvider = now
        self.snapshotRequest = snapshotRequest
        if installsSystemObservers {
            installSystemObservers()
            eventHintSource = ClipboardHistoryCopyEventHintSource { [weak self] in
                Task { @MainActor in
                    await self?.handleKeyHint()
                }
            }
        }
    }

    func setEnabled(
        _ enabled: Bool,
        configuration: ClipboardHistoryMonitoringConfiguration? = nil
    ) async {
        if let configuration {
            self.configuration = configuration
        }
        isEnabled = enabled
        if enabled {
            eventHintSource?.start()
        } else {
            eventHintSource?.stop()
        }
        let plan = scheduler.handle(.setEnabled(enabled), at: now())
        apply(plan)
    }

    func handleLifecycle(_ event: LifecycleEvent) async {
        let schedulerEvent: ClipboardHistoryMonitorScheduler.Event
        switch event {
        case .willSleep:
            schedulerEvent = .willSleep
            eventHintSource?.stop()
        case .didWake:
            schedulerEvent = .didWake
            if isEnabled {
                eventHintSource?.start()
            }
        case .screenLocked:
            schedulerEvent = .screenLocked
            eventHintSource?.stop()
        case .screenUnlocked:
            schedulerEvent = .screenUnlocked
            if isEnabled {
                eventHintSource?.start()
            }
        case .migrationStarted:
            schedulerEvent = .migrationStarted
        case .migrationCompleted:
            schedulerEvent = .migrationCompleted
        }
        apply(scheduler.handle(schedulerEvent, at: now()))
    }

    func updateConfiguration(
        _ configuration: ClipboardHistoryMonitoringConfiguration
    ) {
        self.configuration = configuration
    }

    func establishBaseline() {
        lastGeneration = pasteboard.changeCount
        pendingCopyEventSource = nil
    }

    func observeForTesting() async {
        await observe()
    }

    func keyHintForTesting() async {
        await handleKeyHint()
    }

    func timerFiredForTesting() async {
        await timerFired()
    }

    private func handleKeyHint() async {
        os_signpost(
            .event,
            log: clipboardMonitorSignpostLog,
            name: "CopyKeyHint"
        )
        instrumentation.recordKeyHint()
        let source = sourceProvider()
        let plan = scheduler.handle(.keyHint, at: now())
        if let source, let deadline = plan.copyEventWindowDeadline {
            pendingCopyEventSource = PendingCopyEventSource(
                source: source,
                deadline: deadline
            )
        } else {
            pendingCopyEventSource = nil
        }
        apply(plan)
        if plan.observeNow {
            await observe()
        }
    }

    private func timerFired() async {
        // Doubles as the tap watchdog: re-arming is a no-op while the tap is
        // installed, and recovers it when Accessibility is granted after launch.
        eventHintSource?.ensureInstalled()
        os_signpost(
            .event,
            log: clipboardMonitorSignpostLog,
            name: scheduledTimerIsIdle ? "IdleTimerFire" : "BoostedTimerFire"
        )
        instrumentation.recordTimerFire(isIdle: scheduledTimerIsIdle)
        let plan = scheduler.handle(.timerFired, at: now())
        apply(plan)
        if plan.observeNow {
            await observe()
        }
    }

    private func observe() async {
        guard isActive else { return }
        if observationInFlight {
            observationRequested = true
            return
        }
        observationInFlight = true
        defer { observationInFlight = false }
        let signpostID = OSSignpostID(log: clipboardMonitorSignpostLog)
        os_signpost(
            .begin,
            log: clipboardMonitorSignpostLog,
            name: "PasteboardObservation",
            signpostID: signpostID
        )
        defer {
            os_signpost(
                .end,
                log: clipboardMonitorSignpostLog,
                name: "PasteboardObservation",
                signpostID: signpostID
            )
        }

        repeat {
            observationRequested = false
            let generation = pasteboard.changeCount
            guard generation != lastGeneration else { break }
            instrumentation.recordObservedGeneration(
                previous: lastGeneration,
                current: generation
            )

            if suppression.shouldSuppress(generation: generation) {
                lastGeneration = generation
                pendingCopyEventSource = nil
                apply(
                    scheduler.handle(
                        .observationCompleted(changed: true),
                        at: now()
                    )
                )
                continue
            }

            let metadata = readMetadata(generation: generation)
            let decision = policy.evaluate(
                metadata,
                copyEventSource: activeCopyEventSource(at: now()),
                observationSource: sourceProvider(),
                configuration: configuration
            )
            guard pasteboard.changeCount == generation else {
                observationRequested = true
                continue
            }
            pendingCopyEventSource = nil
            lastGeneration = generation

            switch decision {
            case .exclude:
                break
            case .capture(let source):
                do {
                    let outcome = try await module.capture(
                        snapshotRequest(pasteboard, generation),
                        source: source
                    )
                    if outcome == .skipped(.generationChanged) {
                        observationRequested = true
                    } else if case .captured = outcome {
                        instrumentation.recordCapture()
                        NotificationCenter.default.post(
                            name: .clipboardHistoryV2DidMutate,
                            object: nil
                        )
                    }
                } catch {
                    reportOperationFailureIfNeeded(at: now())
                }
            }

            apply(
                scheduler.handle(
                    .observationCompleted(changed: true),
                    at: now()
                )
            )
        } while observationRequested
    }

    private func reportOperationFailureIfNeeded(at instant: Duration) {
        if let lastOperationFailureReportAt,
            instant - lastOperationFailureReportAt
                < Self.operationFailureReportInterval
        {
            return
        }
        lastOperationFailureReportAt = instant
        NotificationCenter.default.post(
            name: .clipboardHistoryV2OperationDidFail,
            object: nil
        )
    }

    private func readMetadata(
        generation: Int
    ) -> ClipboardHistoryPasteboardMetadata {
        let items = pasteboard.pasteboardItems ?? []
        let advertisedTypes = Set(
            items.flatMap(\.types).map(\.rawValue)
        )
        let sourceType = NSPasteboard.PasteboardType(
            "org.nspasteboard.source"
        )
        let declaredSource = items.lazy.compactMap {
            $0.string(forType: sourceType)
        }.first
        return ClipboardHistoryPasteboardMetadata(
            generation: generation,
            advertisedTypeIdentifiers: advertisedTypes,
            declaredSourceBundleIdentifier: declaredSource
        )
    }

    private func apply(_ plan: ClipboardHistoryMonitorScheduler.Plan) {
        isActive = plan.nextFire != nil
        if plan.copyEventWindowDeadline == nil {
            pendingCopyEventSource = nil
        }
        if plan.establishBaseline {
            lastGeneration = pasteboard.changeCount
            pendingCopyEventSource = nil
        }
        schedule(plan.nextFire)
    }

    private func schedule(
        _ scheduledFire: ClipboardHistoryMonitorScheduler.ScheduledFire?
    ) {
        timer?.invalidate()
        timer = nil
        guard let scheduledFire else { return }
        scheduledTimerIsIdle =
            scheduledFire.tolerance >= .milliseconds(50)

        let delay = max(0, (scheduledFire.deadline - now()).timeInterval)
        let timer = Timer(timeInterval: delay, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                await self?.timerFired()
            }
        }
        timer.tolerance = scheduledFire.tolerance.timeInterval
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func installSystemObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let mappings: [(Notification.Name, LifecycleEvent)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.sessionDidResignActiveNotification, .screenLocked),
            (NSWorkspace.sessionDidBecomeActiveNotification, .screenUnlocked),
        ]
        workspaceObservers = mappings.map { name, event in
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.handleLifecycle(event)
                }
            }
        }
    }

    private func now() -> Duration {
        nowProvider()
    }

    private func activeCopyEventSource(
        at now: Duration
    ) -> ClipboardHistoryApplicationSource? {
        guard let pendingCopyEventSource,
            now < pendingCopyEventSource.deadline
        else {
            pendingCopyEventSource = nil
            return nil
        }
        return pendingCopyEventSource.source
    }

    private static func uptime() -> Duration {
        .nanoseconds(Int64(clamping: DispatchTime.now().uptimeNanoseconds))
    }

    private static func frontmostApplicationSource()
        -> ClipboardHistoryApplicationSource?
    {
        guard let application = NSWorkspace.shared.frontmostApplication,
            let bundleIdentifier = application.bundleIdentifier
        else {
            return nil
        }
        return ClipboardHistoryApplicationSource(
            bundleIdentifier: bundleIdentifier,
            displayName: application.localizedName
        )
    }
}

@MainActor
private final class ClipboardHistoryCopyEventHintSource {
    private nonisolated let scheduleHint: @Sendable () -> Void
    /// Read by the tap callback, which runs on the run loop that installed it
    /// (the main thread) but is not statically main-actor isolated — the same
    /// arrangement HotkeyService uses for its own tap storage.
    private nonisolated(unsafe) var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Whether the hint source is supposed to be observing. Kept separate from
    /// `eventTap` so a create that failed for lack of Accessibility can be
    /// retried later without a stop/start cycle.
    private var isRunning = false

    init(scheduleHint: @escaping @Sendable () -> Void) {
        self.scheduleHint = scheduleHint
    }

    func start() {
        isRunning = true
        ensureInstalled()
    }

    /// Idempotent re-arm, driven off the monitor's existing timer. It covers
    /// the two ways the tap goes away without anyone calling `stop()`:
    /// `tapCreate` returning nil because Accessibility was not granted yet at
    /// first launch, and a tap the system tore down entirely. Without it the
    /// source attribution silently degrades to timer-only polling for the rest
    /// of the session even after the user grants permission.
    func ensureInstalled() {
        guard isRunning, eventTap == nil else { return }
        let mask =
            CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByTimeout.rawValue)
            | CGEventMask(1 << CGEventType.tapDisabledByUserInput.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: clipboardHistoryCopyEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        isRunning = false
        Self.teardown(eventTap: eventTap, runLoopSource: runLoopSource)
        eventTap = nil
        runLoopSource = nil
    }

    /// The system disables a tap that overran its callback budget or was
    /// interrupted by user input. Re-enable it inline from the callback, the
    /// same defence HotkeyService applies to its own tap.
    nonisolated func reenableAfterSystemDisable() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    /// The run loop retains the source, so an installed tap outlives this
    /// object and would call back through a freed `Unmanaged` pointer. Tear it
    /// down here instead of relying on a matching `stop()`.
    isolated deinit {
        Self.teardown(eventTap: eventTap, runLoopSource: runLoopSource)
    }

    private nonisolated static func teardown(
        eventTap: CFMachPort?,
        runLoopSource: CFRunLoopSource?
    ) {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                runLoopSource,
                .commonModes
            )
        }
    }

    nonisolated func receive(_ event: CGEvent) {
        let flags = event.flags.intersection(
            [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        )
        guard flags.contains(.maskCommand),
            !flags.contains(.maskControl),
            !flags.contains(.maskAlternate),
            event.getIntegerValueField(.keyboardEventKeycode) == 8
                || event.getIntegerValueField(.keyboardEventKeycode) == 7
        else {
            return
        }
        // The callback only enqueues the immutable hint closure. Pasteboard
        // access, source sampling, canonicalization, and persistence all happen
        // later on the monitor's serialized path.
        scheduleHint()
    }
}

private func clipboardHistoryCopyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let source = Unmanaged<ClipboardHistoryCopyEventHintSource>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    switch type {
    case .keyDown:
        source.receive(event)
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        source.reenableAfterSystemDisable()
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}
