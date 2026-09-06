import AppKit
import ClipboardHistory
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
    /// Fraction of the usable screen height the panel may occupy when capping.
    private static let panelHeightFraction: CGFloat = 0.8

    private let modelContainer: ModelContainer
    private let clipboardHistoryModule: ClipboardHistoryModule

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    init(
        modelContainer: ModelContainer,
        clipboardHistoryModule: ClipboardHistoryModule
    ) {
        self.modelContainer = modelContainer
        self.clipboardHistoryModule = clipboardHistoryModule
    }

    /// Create the status item. Call once, after launch.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.iconImage(named: MenuBarIcon.currentName)
            button.target = self
            button.action = #selector(statusItemClicked)
            // Receive both left- and right-clicks; we dispatch in the handler.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Dismiss the panel first so the menu doesn't sit on top of it.
            if panel?.isVisible == true { hidePanel() }
            showContextMenu()
            return
        }
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showContextMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        let settingsItem = NSMenuItem(
            title: L(.panelFooterSettings),
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L(.panelFooterQuit),
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // Assigning .menu makes the status item display it for the current
        // click; nil it back out afterwards so the next left-click still
        // routes to our action handler.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettingsFromMenu() {
        // Defer to the next runloop tick: the NSMenu tracking loop is still
        // unwinding here, and activating the app inside it can race with the
        // menu dismissal animation.
        DispatchQueue.main.async {
            SettingsOpener.shared.tryOpen()
        }
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
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
                MenuBarView(
                    onRequestClose: { [weak self] in self?.hidePanel() },
                    clipboardHistoryModule: clipboardHistoryModule
                )
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
        var contentSize = hostingView.fittingSize
        if contentSize.width < 1 || contentSize.height < 1 {
            contentSize = NSSize(width: 260, height: 320)
        }
        hostingView.sizingOptions = []

        // Cap the panel height to a fraction of the usable screen height so a
        // long feature list never runs off-screen; the overflow scrolls inside
        // the panel. With no resolvable screen, leave the height uncapped.
        let maxHeight = (button.window?.screen?.visibleFrame.height)
            .map { $0 * Self.panelHeightFraction } ?? .greatestFiniteMagnitude
        let panelSize = NSSize(
            width: contentSize.width,
            height: min(contentSize.height, max(1, maxHeight))
        )

        let contentView: NSView
        if contentSize.height > panelSize.height {
            // Content taller than the screen: scroll it. The hosting view keeps
            // its full natural height as the scroll document; the scroll view
            // clips to the capped viewport. `sizingOptions = []` already detached
            // window sizing, so nothing here can drive a window resize.
            hostingView.frame = NSRect(origin: .zero, size: contentSize)
            hostingView.autoresizingMask = [.width]
            let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: panelSize))
            scrollView.documentView = hostingView
            Self.configurePanelScrollView(scrollView)
            // Round the viewport so the panel keeps its corner radius even when
            // the SwiftUI content's own rounded background has scrolled off.
            scrollView.wantsLayer = true
            scrollView.layer?.cornerRadius = 12
            scrollView.layer?.cornerCurve = .continuous
            scrollView.layer?.masksToBounds = true
            // NSHostingView is flipped, so the document's top sits at the top;
            // make sure the panel opens scrolled to the first row.
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            contentView = scrollView
        } else {
            // A plain NSView container keeps the hosting view out of the window's
            // constraint-based layout, so nothing can drive a window resize.
            hostingView.frame = NSRect(origin: .zero, size: panelSize)
            hostingView.autoresizingMask = [.width, .height]
            let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
            container.addSubview(hostingView)
            contentView = container
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = contentView
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
        installKeyMonitors()
    }

    private func hidePanel() {
        removeClickMonitors()
        removeKeyMonitors()
        statusItem?.button?.highlight(false)
        // Authoritatively dismiss any hover popover too. A key-focus popover
        // (Port Manager / clipboard history) makes the panel's `onDisappear`
        // skip `popover.hide()`, which would otherwise orphan the
        // `KeyableHoverPanel` as a zombie window once MenuBarView is torn down.
        for case let hoverPanel as KeyableHoverPanel in NSApp.windows where hoverPanel.isVisible {
            hoverPanel.orderOut(nil)
        }
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

    static func configurePanelScrollView(_ scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller = nil
        scrollView.horizontalScroller = nil
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
    }

    // MARK: - Outside-click dismissal

    private func installClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: MainThreadEventMonitor.global { [weak self] in
                guard let self else { return }
                let decision = MenuBarEventMonitorPolicy.globalClickDecision(
                    mouseLocation: NSEvent.mouseLocation,
                    panelFrame: self.panel?.frame,
                    statusItemFrame: self.statusItemFrame(),
                    hoverPanelFrames: self.hoverPanelFrames()
                )
                if decision == .close { self.hidePanel() }
            }
        )
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: MainThreadEventMonitor.localMouse { [weak self] clickWindowNumber in
                guard let self else { return }
                let decision = MenuBarEventMonitorPolicy.clickDecision(
                    clickWindowNumber: clickWindowNumber,
                    panelWindowNumber: self.panel?.windowNumber,
                    statusWindowNumber: self.statusItem?.button?.window?.windowNumber,
                    hoverPanelWindowNumbers: self.hoverPanelWindowNumbers()
                )
                if decision == .close {
                    self.hidePanel()
                }
            }
        )
    }

    private func removeClickMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    // MARK: - Escape-to-dismiss

    /// Hide the panel when the user presses Escape. The panel is a
    /// `.nonactivatingPanel`, so it never becomes key — a plain `.keyDown`
    /// handler in the SwiftUI view wouldn't fire. A global monitor catches
    /// Escape when another app is frontmost; the local monitor covers the
    /// rare case where our own app is active (e.g. Settings window open).
    private func installKeyMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown,
            handler: MainThreadEventMonitor.globalKey { [weak self] keyCode in
                guard MenuBarEventMonitorPolicy.escapeDecision(keyCode: keyCode) == .closeAndConsume else { return }
                self?.hidePanel()
            }
        )
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown,
            handler: MainThreadEventMonitor.localKey { [weak self] keyCode in
                guard MenuBarEventMonitorPolicy.escapeDecision(keyCode: keyCode) == .closeAndConsume else { return false }
                self?.hidePanel()
                return true
            }
        )
    }

    private func removeKeyMonitors() {
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }

    private func statusItemFrame() -> NSRect? {
        guard let button = statusItem?.button,
              let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func hoverPanelWindowNumbers() -> Set<Int> {
        Set(NSApp.windows.compactMap { window in
            window is KeyableHoverPanel ? window.windowNumber : nil
        })
    }

    private func hoverPanelFrames() -> [NSRect] {
        NSApp.windows.compactMap { window in
            window is KeyableHoverPanel && window.isVisible ? window.frame : nil
        }
    }

    // MARK: - Icon image

    private static func iconImage(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AnyDoor")
        image?.isTemplate = true
        return image
    }
}
