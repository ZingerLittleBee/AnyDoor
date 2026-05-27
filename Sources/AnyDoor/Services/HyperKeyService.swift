import Foundation
import AppKit
import OSLog
import Observation

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "hyperKey.service")

@MainActor
@Observable
final class HyperKeyService {
    static let shared = HyperKeyService()

    private let defaults = UserDefaults.standard
    private let triggerKey = "hyperKey.trigger"
    private let quickPressKey = "hyperKey.quickPress"
    private let includeShiftKey = "hyperKey.includeShift"

    private(set) var trigger: HyperKeyTrigger
    private(set) var quickPress: HyperKeyQuickPress
    private(set) var includeShift: Bool

    private(set) var isActive: Bool = false
    private(set) var isApplying: Bool = false
    private(set) var lastError: HyperKeyError?

    private var mutationToken: UInt64 = 0
    private var watchdogTimer: Timer?

    var hyperModifierFlags: Int {
        guard trigger != .none, isActive else { return 0 }
        let base = Int(NSEvent.ModifierFlags.control.rawValue
                       | NSEvent.ModifierFlags.option.rawValue
                       | NSEvent.ModifierFlags.command.rawValue)
        let shift = Int(NSEvent.ModifierFlags.shift.rawValue)
        return base | (includeShift ? shift : 0)
    }

    var virtualKeyCode: Int {
        isActive ? HyperKeyVirtualKey.f19.keyCode : -1
    }

    init() {
        let raw = defaults.string(forKey: triggerKey) ?? HyperKeyTrigger.none.rawValue
        self.trigger = HyperKeyTrigger(rawValue: raw) ?? .none
        let qpRaw = defaults.string(forKey: quickPressKey) ?? HyperKeyQuickPress.doesNothing.rawValue
        self.quickPress = HyperKeyQuickPress(rawValue: qpRaw) ?? .doesNothing
        self.includeShift = defaults.object(forKey: includeShiftKey) as? Bool ?? true
    }

    /// Called once from AppDelegate after HotkeyService is up. Runs Phase 2
    /// (gated apply) and starts the watchdog.
    func bootstrapAfterTap() async {
        startWatchdog()
        guard trigger != .none else { return }
        await applyCurrent()
    }

    func setTrigger(_ new: HyperKeyTrigger) async {
        mutationToken &+= 1
        let myToken = mutationToken
        trigger = new
        defaults.set(new.rawValue, forKey: triggerKey)
        await drive(token: myToken)
    }

    func setQuickPress(_ new: HyperKeyQuickPress) async {
        quickPress = new
        defaults.set(new.rawValue, forKey: quickPressKey)
        pushConfig()
    }

    func setIncludeShift(_ new: Bool) async {
        includeShift = new
        defaults.set(new, forKey: includeShiftKey)
        pushConfig()
    }

    private func drive(token: UInt64) async {
        isApplying = true
        defer { isApplying = false }

        switch trigger {
        case .none:
            do {
                try await HyperKeyController.shared.clear()
                guard token == mutationToken else { return }
                isActive = false
                lastError = nil
                pushConfig()
            } catch let err as HyperKeyError {
                lastError = err
                isActive = false
                pushConfig()
            } catch {
                lastError = .hidutilFailed(stderr: String(describing: error))
                isActive = false
                pushConfig()
            }
        default:
            let health = HotkeyService.shared.tapHealth
            if case .failed = health {
                lastError = .tapNotRunning
                isActive = false
                pushConfig()
                return
            }
            do {
                _ = try await HyperKeyController.shared.apply(trigger: trigger, virtualKey: .f19)
                guard token == mutationToken else { return }
                isActive = true
                lastError = nil
                pushConfig()
            } catch let err as HyperKeyError {
                guard token == mutationToken else { return }
                lastError = err
                isActive = false
                trigger = .none
                defaults.set(HyperKeyTrigger.none.rawValue, forKey: triggerKey)
                pushConfig()
            } catch {
                guard token == mutationToken else { return }
                lastError = .hidutilFailed(stderr: String(describing: error))
                isActive = false
                trigger = .none
                defaults.set(HyperKeyTrigger.none.rawValue, forKey: triggerKey)
                pushConfig()
            }
        }
    }

    private func applyCurrent() async {
        mutationToken &+= 1
        await drive(token: mutationToken)
    }

    private func pushConfig() {
        HotkeyService.shared.updateHyperConfig(
            virtualKey: virtualKeyCode,
            flags: hyperModifierFlags,
            quickPress: quickPress
        )
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
    }

    private func watchdogTick() {
        let health = HotkeyService.shared.tapHealth

        switch health {
        case .failed:
            if trigger != .none && isActive {
                logger.error("Tap health failed, emergency clearing hyper mapping")
                Task {
                    try? await HyperKeyController.shared.clear()
                    isActive = false
                    lastError = .tapNotRunning
                    pushConfig()
                }
            }
        case .healthy:
            if trigger != .none && !isActive && lastError == .tapNotRunning {
                Task { await applyCurrent() }
            }
        case .suspendedByRecorder, .transientlyDown:
            break
        }
    }
}
