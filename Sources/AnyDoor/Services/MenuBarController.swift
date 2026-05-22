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
    private var hostingController: NSHostingController<AnyView>?
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

        let hosting = NSHostingController(
            rootView: AnyView(
                MenuBarView(onRequestClose: { [weak self] in self?.hidePanel() })
                    .modelContainer(modelContainer)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            )
        )
        hosting.sizingOptions = [.preferredContentSize]
        hostingController = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        self.panel = panel

        // Size to the SwiftUI content before showing to avoid a resize flash.
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            panel.setContentSize(fitting)
        }

        positionPanel(panel, under: button)
        panel.orderFrontRegardless()
        button.highlight(true)
        installClickMonitors()
    }

    private func hidePanel() {
        removeClickMonitors()
        statusItem?.button?.highlight(false)
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
        hostingController = nil
    }

    /// Anchor the panel's top-right corner just below the status item.
    private func positionPanel(_ panel: NSPanel, under button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonInScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let size = panel.frame.size
        var origin = NSPoint(
            x: buttonInScreen.maxX - size.width,
            y: buttonInScreen.minY - size.height - 4
        )
        if let screen = buttonWindow.screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = max(origin.y, visible.minY + 4)
        }
        panel.setFrameOrigin(origin)
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
