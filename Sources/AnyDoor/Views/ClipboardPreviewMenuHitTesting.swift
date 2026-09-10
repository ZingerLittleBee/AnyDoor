import AppKit

/// Menu windows can extend beyond the preview and can belong to Quick Look's
/// renderer process. Keep their hit testing in Quartz coordinates throughout.
enum ClipboardPreviewMenuHitTesting {
    struct Window: Sendable {
        let frame: CGRect
        let level: Int
        var alpha: Double = 1
        var ignoresMouseEvents = false
        var number: Int = 0
    }

    @MainActor
    static func contains(
        _ event: NSEvent,
        loadWindows: @MainActor () -> [Window] = onScreenWindows
    ) -> Bool {
        if let window = event.window {
            return !window.ignoresMouseEvents && window.level == .popUpMenu
        }
        guard let cgEvent = event.cgEvent else { return false }
        let receivingWindow = Int(cgEvent.getIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        ))
        let targetWindowNumber = receivingWindow > 0 ? receivingWindow
            : (event.windowNumber > 0 ? event.windowNumber : nil)
        return containsMenu(
            at: cgEvent.location, in: loadWindows(), targetWindowNumber: targetWindowNumber
        )
    }

    @MainActor
    private static func onScreenWindows() -> [Window] {
        guard let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return [] }
        return info.compactMap { item -> Window? in
            guard let level = item[kCGWindowLayer as String] as? Int,
                  let number = item[kCGWindowNumber as String] as? Int,
                  let alpha = item[kCGWindowAlpha as String] as? Double,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return Window(
                frame: frame,
                level: level,
                alpha: alpha,
                ignoresMouseEvents: NSApp.window(withWindowNumber: number)?.ignoresMouseEvents == true,
                number: number
            )
        }
    }

    /// `windows` is ordered front-to-back, as returned by CGWindowList.
    static func containsMenu(
        at point: CGPoint,
        in windows: [Window],
        targetWindowNumber: Int? = nil
    ) -> Bool {
        guard let window = windows.first(where: {
            $0.alpha > 0 && !$0.ignoresMouseEvents && $0.frame.contains(point)
                && (targetWindowNumber == nil || $0.number == targetWindowNumber)
        }) else { return false }
        // Prefer the event's receiver when available: remote click-through
        // overlays can cover a menu without being the target of the click.
        // Test the first hit before filtering by level: an unrelated window
        // covering a menu must not turn into an inside-preview interaction.
        // The legacy .submenu level also covers ordinary floating windows.
        return window.level == NSWindow.Level.popUpMenu.rawValue
    }
}
