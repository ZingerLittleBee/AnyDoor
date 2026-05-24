import AppKit
import SwiftData
import SwiftUI

/// Owns the menu bar status item and the click-to-open panel.
///
/// Replaces SwiftUI's `MenuBarExtra`: binding `MenuBarExtra(isInserted:)` to a
/// `false` value drives an infinite `scenesDidChange` transaction storm on
/// macOS 26 that pegs the main thread. Driving `NSStatusItem.isVisible`
/// directly toggles the icon with no scene-graph involvement.
@MainActor
final class MenuBarController {
    private let modelContainer: ModelContainer

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Create the status item. Call once, after launch.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.iconImage(named: MenuBarIcon.currentName)
            button.target = self
            button.action = #selector(statusItemClicked)
        }
        item.isVisible = MenuBarIcon.isVisible
        statusItem = item
    }

    /// Re-read the icon preferences and update the status item. Cheap enough to
    /// call on every `UserDefaults.didChangeNotification`.
    func syncFromPreferences() {
        guard let statusItem else { return }
        statusItem.isVisible = MenuBarIcon.isVisible
        statusItem.button?.image = Self.iconImage(named: MenuBarIcon.currentName)
        if !MenuBarIcon.isVisible { hidePanel() }
    }

    // MARK: - Panel

    @objc private func statusItemClicked() {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }

        // `\.locale` is captured at show time, not reactively rebound. That's
        // OK in practice because the panel auto-dismisses when the Settings
        // window receives focus, so any language change initiated from
        // Settings closes this panel first; the next showPanel() rebuilds the
        // host view with the fresh locale. `LocalizedText` further bypasses
        // `\.locale` (reads `LocalizationManager.shared` directly), so even
        // if a language change ever races with an open panel, visible labels
        // re-render correctly.
        let hostingView = NSHostingView(
            rootView: AnyView(
                MenuBarView(onRequestClose: { [weak self] in self?.hidePanel() })
                    .modelContainer(modelContainer)
                    .environment(LocalizationManager.shared)
                    .environment(\.locale, LocalizationManager.shared.effectiveLocale)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            )
        )
        // Measure the SwiftUI content once, then DETACH the hosting view from
        // window sizing. With sizing enabled NSHostingView resizes its window
        // from within layout, which recurses straight back into window layout
        // — that pegs the CPU and overflows the stack.
        hostingView.sizingOptions = .intrinsicContentSize
        hostingView.layoutSubtreeIfNeeded()
        var size = hostingView.fittingSize
        if size.width < 1 || size.height < 1 {
            size = NSSize(width: 260, height: 320)
        }
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // A plain NSView container keeps the hosting view out of the window's
        // constraint-based layout, so nothing can drive a window resize.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(hostingView)
        panel.contentView = container
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        self.panel = panel
        self.hostingView = hostingView

        positionPanel(panel, under: button)
        panel.orderFrontRegardless()
        button.highlight(true)
        installClickMonitors()
    }

    private func hidePanel() {
        removeClickMonitors()
        statusItem?.button?.highlight(false)
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hostingView = nil
    }

    /// Anchor the panel's leading edge directly below the status item.
    private func positionPanel(_ panel: NSPanel, under button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonInScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let origin = Self.panelOrigin(
            forStatusItemFrame: buttonInScreen,
            panelSize: panel.frame.size,
            visibleFrame: buttonWindow.screen?.visibleFrame
        )
        panel.setFrameOrigin(origin)
    }

    static func panelOrigin(
        forStatusItemFrame statusItemFrame: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect?
    ) -> NSPoint {
        var origin = NSPoint(
            x: statusItemFrame.minX,
            y: statusItemFrame.minY - panelSize.height - 4
        )
        if let visible = visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - panelSize.width - 4)
            origin.y = max(origin.y, visible.minY + 4)
        }
        return origin
    }

    // MARK: - Outside-click dismissal

    private func installClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            // `windowNumber` is Sendable; `NSEvent`/`NSWindow` are not, so the
            // clicked window is reduced to an Int before hopping to the actor.
            let clickWindowNumber = event.window?.windowNumber
            MainActor.assumeIsolated {
                guard let self else { return }
                // Keep the panel open for clicks inside it, inside a hover
                // side-popover, or on the status item (its action toggles).
                if clickWindowNumber == self.panel?.windowNumber { return }
                if clickWindowNumber == self.statusItem?.button?.window?.windowNumber { return }
                if let n = clickWindowNumber,
                   NSApp.windows.contains(where: { $0.windowNumber == n && $0 is KeyableHoverPanel }) {
                    return
                }
                self.hidePanel()
            }
            return event
        }
    }

    private func removeClickMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    // MARK: - Icon image

    private static func iconImage(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AnyDoor")
        image?.isTemplate = true
        return image
    }
}
