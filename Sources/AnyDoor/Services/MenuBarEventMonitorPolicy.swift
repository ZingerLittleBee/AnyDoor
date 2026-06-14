import AppKit

enum MenuBarEventMonitorPolicy {
    enum ClickDecision: Equatable {
        case keepOpen
        case close
    }

    enum EscapeDecision: Equatable {
        case ignore
        case closeAndConsume
    }

    static func clickDecision(
        clickWindowNumber: Int?,
        panelWindowNumber: Int?,
        statusWindowNumber: Int?,
        hoverPanelWindowNumbers: Set<Int>
    ) -> ClickDecision {
        guard let clickWindowNumber else { return .close }
        if clickWindowNumber == panelWindowNumber { return .keepOpen }
        if clickWindowNumber == statusWindowNumber { return .keepOpen }
        if hoverPanelWindowNumbers.contains(clickWindowNumber) { return .keepOpen }
        return .close
    }

    static func globalClickDecision(
        mouseLocation: NSPoint,
        panelFrame: NSRect?,
        statusItemFrame: NSRect?,
        hoverPanelFrames: [NSRect]
    ) -> ClickDecision {
        if panelFrame?.contains(mouseLocation) == true { return .keepOpen }
        if statusItemFrame?.contains(mouseLocation) == true { return .keepOpen }
        if hoverPanelFrames.contains(where: { $0.contains(mouseLocation) }) { return .keepOpen }
        return .close
    }

    static func escapeDecision(keyCode: UInt16) -> EscapeDecision {
        keyCode == 53 ? .closeAndConsume : .ignore
    }
}

enum MainThreadEventMonitor {
    nonisolated static func global(_ action: @escaping @MainActor () -> Void) -> (NSEvent) -> Void {
        { _ in
            MainThreadIsolation.run { action() }
        }
    }

    nonisolated static func globalKey(_ action: @escaping @MainActor (UInt16) -> Void) -> (NSEvent) -> Void {
        { event in
            let keyCode = event.keyCode
            MainThreadIsolation.run { action(keyCode) }
        }
    }

    nonisolated static func localMouse(_ action: @escaping @MainActor (Int?) -> Void) -> (NSEvent) -> NSEvent? {
        { event in
            let windowNumber = event.window?.windowNumber
            MainThreadIsolation.run { action(windowNumber) }
            return event
        }
    }

    nonisolated static func localKey(_ action: @escaping @MainActor (UInt16) -> Bool) -> (NSEvent) -> NSEvent? {
        { event in
            let keyCode = event.keyCode
            let consumed = MainThreadIsolation.run { action(keyCode) }
            return consumed ? nil : event
        }
    }
}
