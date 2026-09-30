import AppKit
import Observation
import PluginInterface
import PluginSupport
import SwiftUI

/// The image and toolbar are separate windows: only the image becomes
/// click-through, so the toolbar can always disable it or close the pin.
@MainActor
final class PinnedImageWindow: NSObject, NSWindowDelegate {
    private static var windows: [PinnedImageWindow] = []

    let panel: NSPanel
    let toolbarPanel: NSPanel
    let state = PinnedImageState()
    private var isClosed = false
    nonisolated(unsafe) private var escapeMonitorLocal: Any?
    nonisolated(unsafe) private var escapeMonitorGlobal: Any?

    static func show(image: NSImage, at screenFrame: CGRect) {
        let window = PinnedImageWindow(image: image, at: screenFrame)
        windows.append(window)
        window.panel.orderFrontRegardless()
        window.updateHover()
    }

    init(image: NSImage, at screenFrame: CGRect) {
        let size = PinnedImageLayout.initialSize(for: image.size)
        let frame = CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width, height: size.height
        )
        panel = Self.makePanel(frame: frame)
        toolbarPanel = Self.makeToolbarPanel(frame: PinnedImageLayout.toolbarFrame(for: frame))
        super.init()
        panel.delegate = self

        // The image's AppKit surface owns drawing, mouse events, and cursor
        // arbitration. An enclosing NSHostingView also handles cursorUpdate,
        // which can replace a cursor set by an embedded representable.
        let imageSurface = PinnedImageDragView(frame: CGRect(origin: .zero, size: size))
        imageSurface.image = image
        imageSurface.toolTip = L(.capturePinnedMoveResize)
        imageSurface.onHoverChanged = { [weak self] in self?.updateHover() }
        imageSurface.autoresizingMask = [.width, .height]
        panel.contentView = imageSurface

        let toolbarHost = PinnedImageToolbarHostingView(rootView: PinnedImageToolbar(
            state: state,
            onClose: { [weak self] in self?.close() },
            onOpacity: { [weak self] value in self?.panel.alphaValue = value },
            onToggleClickThrough: { [weak self] in self?.setClickThrough(!(self?.state.clickThrough ?? false)) },
            onHoverChanged: { [weak self] in self?.updateHover() }
        ).environment(LocalizationManager.shared))
        toolbarHost.sizingOptions = []
        toolbarHost.frame = CGRect(origin: .zero, size: PinnedImageLayout.toolbarSize)
        toolbarHost.autoresizingMask = [.width, .height]
        toolbarPanel.contentView = toolbarHost
    }

    static func makePanel(frame: CGRect) -> NSPanel {
        let panel = PinnedImagePanel(
            contentRect: frame,
            // Native borderless resizing bypassed the desired minimum on
            // supported systems. Our inside-edge handler owns every resize.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        configure(panel)
        panel.minSize = PinnedImageLayout.minimumSize
        panel.contentMinSize = PinnedImageLayout.minimumSize
        return panel
    }

    private static func makeToolbarPanel(frame: CGRect) -> NSPanel {
        let panel = PinnedImageToolbarPanel(
            contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        configure(panel)
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    private static func configure(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func setClickThrough(_ enabled: Bool) {
        guard !isClosed else { return }
        state.clickThrough = enabled
        panel.ignoresMouseEvents = enabled
        // A separate child window is independently hit-tested by the Window
        // Server. NSView.hitTest(nil) cannot pass through to another application.
        toolbarPanel.ignoresMouseEvents = false
        if enabled {
            installEscapeMonitors()
        } else {
            removeEscapeMonitors()
        }
        updateHover()
    }

    private func updateHover() {
        state.hovering = panel.frame.contains(NSEvent.mouseLocation)
        (panel.contentView as? PinnedImageDragView)?.isHovered = state.hovering
        updateToolbarVisibility()
        (panel.contentView as? PinnedImageDragView)?.refreshCursorForCurrentLocation()
    }

    private func updateToolbarVisibility() {
        guard panel.isVisible, !isClosed else { return }
        if state.toolbarVisible {
            layoutToolbar()
            if toolbarPanel.parent == nil { panel.addChildWindow(toolbarPanel, ordered: .above) }
            toolbarPanel.orderFrontRegardless()
        } else {
            panel.removeChildWindow(toolbarPanel)
            toolbarPanel.orderOut(nil)
        }
    }

    private func layoutToolbar() {
        toolbarPanel.setFrame(PinnedImageLayout.toolbarFrame(for: panel.frame), display: true)
        (panel.contentView as? PinnedImageDragView)?.refreshCursorForCurrentLocation()
    }

    func windowDidResize(_ notification: Notification) { layoutToolbar() }
    func windowDidMove(_ notification: Notification) { layoutToolbar() }

    /// Escape remains a convenience; the permanently visible toolbar is the
    /// primary recovery path and does not need global keyboard permissions.
    private func installEscapeMonitors() {
        guard escapeMonitorLocal == nil, escapeMonitorGlobal == nil else { return }
        escapeMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainThreadIsolation.run { Self.disableAllClickThrough() }
            return nil
        }
        escapeMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            MainThreadIsolation.run { Self.disableAllClickThrough() }
        }
    }

    private static func disableAllClickThrough() {
        // The first local monitor consumes Escape. Restore every pin before
        // doing so instead of leaving other click-through windows stranded.
        for window in windows where window.state.clickThrough { window.setClickThrough(false) }
    }

    private func removeEscapeMonitors() {
        if let monitor = escapeMonitorLocal { NSEvent.removeMonitor(monitor); escapeMonitorLocal = nil }
        if let monitor = escapeMonitorGlobal { NSEvent.removeMonitor(monitor); escapeMonitorGlobal = nil }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        removeEscapeMonitors()
        panel.removeChildWindow(toolbarPanel)
        // Detaching the hosts also cancels pending tooltip/hover callbacks.
        toolbarPanel.contentView = nil
        toolbarPanel.close()
        panel.delegate = nil
        panel.contentView = nil
        panel.close()
        Self.windows.removeAll { $0 === self }
    }
}

@MainActor
@Observable
final class PinnedImageState {
    var clickThrough = false
    var hovering = false
    var opacity: Double = 1

    var toolbarVisible: Bool { clickThrough || hovering }
    var clickThroughSymbol: String { clickThrough ? "cursorarrow.slash" : "cursorarrow" }
    var clickThroughHelp: L10n.Key { clickThrough ? .capturePinnedDisableClickThrough : .capturePinnedClickThrough }
}

private final class PinnedImageToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class PinnedImageToolbarHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct PinnedImageToolbar: View {
    @Bindable var state: PinnedImageState
    let onClose: () -> Void
    let onOpacity: (CGFloat) -> Void
    let onToggleClickThrough: () -> Void
    let onHoverChanged: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $state.opacity, in: 0.2...1).frame(width: 80)
                .onChange(of: state.opacity) { _, value in onOpacity(CGFloat(value)) }
                .hoverTooltip(L(.capturePinnedOpacity), activeAlways: true)
            Button(action: onToggleClickThrough) {
                Image(systemName: state.clickThroughSymbol)
                    .foregroundStyle(state.clickThrough ? Color.accentColor : Color.primary)
                    .frame(width: 20, height: 20)
                    .background(state.clickThrough ? Color.accentColor.opacity(0.2) : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(state.clickThroughHelp))
            .hoverTooltip(L(state.clickThroughHelp), activeAlways: true)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(.clipboardPreviewClose))
            .hoverTooltip(L(.clipboardPreviewClose), activeAlways: true)
        }
        .padding(.horizontal, 10)
        .frame(width: PinnedImageLayout.toolbarSize.width, height: PinnedImageLayout.toolbarSize.height)
        .background(.ultraThinMaterial, in: Capsule())
        .onHoverSafe { _ in onHoverChanged() }
        .focusEffectDisabled()
    }
}
