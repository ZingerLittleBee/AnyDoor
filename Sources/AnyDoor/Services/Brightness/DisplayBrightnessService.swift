import Foundation
import AppKit
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "brightness.service")

struct DisplayInfo: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let supportsDDC: Bool
}

@MainActor
@Observable
final class DisplayBrightnessService {
    static let shared = DisplayBrightnessService()

    private(set) var displays: [DisplayInfo] = []
    private(set) var levels: [CGDirectDisplayID: Float] = [:]
    private(set) var isLoading: Set<CGDirectDisplayID> = []

    /// Monotonic counter per display, incremented on every level mutation.
    /// Used by deferred backfill reads to drop themselves when a newer user
    /// action has superseded them.
    private var levelGeneration: [CGDirectDisplayID: UInt64] = [:]

    private var controller: BrightnessController?
    private var screenChangeObserver: NSObjectProtocol?
    private var pendingWrites: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private static let writeDebounceNanos: UInt64 = 30_000_000   // 30 ms

    enum BumpTarget: Sendable { case displayUnderMouse }

    init() {}

    func bootstrap(controller: BrightnessController) {
        self.controller = controller
        installScreenObserver()
    }

    private func installScreenObserver() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    /// Re-enumerate NSScreen.screens; probe + read every external display.
    func refresh() async {
        guard let controller else { return }

        let externalIDs = Self.externalDisplayIDs()
        var newDisplays: [DisplayInfo] = []
        var rawNames: [(CGDirectDisplayID, String)] = []

        for id in externalIDs {
            let baseName = Self.localizedName(for: id) ?? "Display \(id)"
            rawNames.append((id, baseName))
        }

        let dedupedNames = Self.dedupedNames(rawNames)

        for (id, name) in zip(externalIDs, dedupedNames) {
            isLoading.insert(id)
            let supports = await controller.probe(displayID: id)
            newDisplays.append(DisplayInfo(id: id, name: name, supportsDDC: supports))
            if supports {
                if let value = await controller.read(displayID: id) {
                    levels[id] = value
                }
            }
            isLoading.remove(id)
        }

        // Drop entries for unplugged displays.
        let present = Set(newDisplays.map(\.id))
        for stale in levels.keys where !present.contains(stale) { levels.removeValue(forKey: stale) }

        displays = newDisplays
    }

    /// Slider drag entry. Updates UI immediately; debounces DDC write.
    func setBrightness(_ value: Float, for displayID: CGDirectDisplayID) {
        guard let controller else { return }
        let clamped = max(0, min(1, value))
        levels[displayID] = clamped
        bumpGeneration(displayID)
        pendingWrites[displayID]?.cancel()
        pendingWrites[displayID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.writeDebounceNanos)
            if Task.isCancelled { return }
            try? await controller.write(displayID: displayID, value: clamped)
            await MainActor.run { [weak self] in
                self?.pendingWrites[displayID] = nil
            }
        }
    }

    /// Hotkey bump entry.
    func bump(_ delta: Float, target: BumpTarget) {
        guard let displayID = resolveTarget(target) else { return }
        bumpInternal(delta, displayID: displayID, showOSD: true)
    }

    // MARK: - Internal (also reused by test seams)

    fileprivate func bumpInternal(_ delta: Float, displayID: CGDirectDisplayID, showOSD: Bool) {
        guard let controller else { return }
        let usedFallback = (levels[displayID] == nil)
        let baseline = levels[displayID] ?? 0.5
        let newValue = max(0, min(1, baseline + delta))
        bumpGeneration(displayID)
        let gen = levelGeneration[displayID] ?? 0
        levels[displayID] = newValue

        if showOSD {
            OSDBridge.showBrightness(newValue, on: displayID)
        }

        // Task started from a @MainActor method in Swift 6 inherits MainActor
        // isolation. The actor `await controller.write/read` hops away and back
        // automatically, so direct `self.levelGeneration[...]` checks are
        // MainActor-safe without explicit MainActor.run wrappers.
        Task { [weak self] in
            do {
                try await controller.write(displayID: displayID, value: newValue)
            } catch {
                return
            }
            guard let self else { return }
            guard usedFallback else { return }
            guard self.levelGeneration[displayID] == gen else { return }
            guard let real = await controller.read(displayID: displayID) else { return }
            guard self.levelGeneration[displayID] == gen else { return }
            self.levels[displayID] = real
        }
    }

    private func bumpGeneration(_ id: CGDirectDisplayID) {
        levelGeneration[id, default: 0] &+= 1
    }

    private func resolveTarget(_ target: BumpTarget) -> CGDirectDisplayID? {
        switch target {
        case .displayUnderMouse:
            return Self.displayUnderMouse(displays: displays) ?? Self.mainDisplayIfSupported(displays: displays)
        }
    }

    // MARK: - Static helpers (pure functions, no MainActor state)

    private static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.filter { CGDisplayIsBuiltin($0) == 0 }
    }

    private static func localizedName(for displayID: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber,
               number.uint32Value == displayID {
                return screen.localizedName
            }
        }
        return nil
    }

    fileprivate static func dedupedNames(_ pairs: [(CGDirectDisplayID, String)]) -> [String] {
        var counts: [String: Int] = [:]
        // Stable: first occurrence keeps the bare name, subsequent get " (n)".
        let sorted = pairs.sorted { $0.0 < $1.0 }
        var result = Array(repeating: "", count: pairs.count)
        var assigned: [CGDirectDisplayID: String] = [:]
        for (id, name) in sorted {
            let n = counts[name] ?? 0
            assigned[id] = (n == 0) ? name : "\(name) (\(n))"
            counts[name] = n + 1
        }
        for (i, pair) in pairs.enumerated() { result[i] = assigned[pair.0] ?? pair.1 }
        return result
    }

    private static func displayUnderMouse(displays: [DisplayInfo]) -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(mouse) {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber {
                let id = number.uint32Value
                if displays.contains(where: { $0.id == id && $0.supportsDDC }) { return id }
            }
        }
        return nil
    }

    private static func mainDisplayIfSupported(displays: [DisplayInfo]) -> CGDirectDisplayID? {
        let id = CGMainDisplayID()
        return displays.contains(where: { $0.id == id && $0.supportsDDC }) ? id : nil
    }
}

// MARK: - Test seams (XCTest @testable import)

extension DisplayBrightnessService {
    func injectDisplaysForTesting(_ d: [DisplayInfo]) { self.displays = d }
    func setLevelForTesting(_ v: Float, for id: CGDirectDisplayID) { levels[id] = v }
    func bumpForTesting(_ delta: Float, displayID: CGDirectDisplayID) {
        bumpInternal(delta, displayID: displayID, showOSD: false)
    }
}
