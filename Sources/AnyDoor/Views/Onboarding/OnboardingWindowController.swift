import AppKit
import SwiftUI

/// Hosts the first-run onboarding flow in a real, reopenable window.
///
/// The window is **borderless** (no title bar / traffic lights) — a floating,
/// rounded card. Mirrors `AnnotationEditorWindow` for lifecycle: single-instance,
/// registered with `RegularWindowCoordinator` so a Dock icon appears while it's
/// open, opted out of state restoration (`isRestorable = false`), and retained
/// by `self` (so `isReleasedWhenClosed = false`). Closing for any reason — Done,
/// Skip, or programmatic close — marks onboarding complete, so it never
/// auto-shows again; the user can reopen it from Settings.
@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?
    private var closeRelay: OnboardingCloseRelay?

    private init() {}

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let size = CGSize(width: 680, height: 520)
        let cornerRadius: CGFloat = 16
        let w = OnboardingPanelWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.title = L(.onboardingWindowTitle)
        w.isRestorable = false
        // Retained in `self.window` and released on close, so AppKit must not
        // also auto-release it — otherwise the window is over-released. Matches
        // every other window/panel controller in the app.
        w.isReleasedWhenClosed = false
        // Frameless, rounded, floating card: clear window so the SwiftUI content
        // paints its own rounded background; keep the system drop shadow; let the
        // user drag it by the background since there's no title bar.
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.center()

        // PROTOTYPE(onboarding-ui): OnboardingPrototypeHost wraps OnboardingView plus
        // two TourKit-based variants behind a DEBUG-only floating switcher. Revert to
        // `OnboardingView { … }` when the prototype is settled — see OnboardingPrototype.swift.
        let root = OnboardingPrototypeHost { [weak self] in
            self?.window?.close()
        }
        .environment(LocalizationManager.shared)
        .environment(\.locale, LocalizationManager.shared.effectiveLocale)
        // Opaque rounded background + hairline border so the borderless window
        // reads as a card and doesn't show the desktop through it.
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )

        let hosting = NSHostingView(rootView: root)
        hosting.layer?.cornerRadius = cornerRadius
        w.contentView = hosting
        w.invalidateShadow()

        let relay = OnboardingCloseRelay()
        relay.onClose = { [weak self] in
            // Any dismissal counts as "seen" so the flow never nags again.
            OnboardingState.markCompleted()
            self?.window = nil
            self?.closeRelay = nil
        }
        w.delegate = relay
        closeRelay = relay
        window = w

        RegularWindowCoordinator.shared.track(w)
        // The app may be `.accessory` and not frontmost on first launch.
        // Activate (now `.regular` via track) and front the window, mirroring
        // AnnotationEditorWindow / SettingsOpener.
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// A borderless window that can still become key/main — required so the flow's
/// keyboard shortcuts (Esc / Return), pickers, and focus work. A plain
/// borderless `NSWindow` refuses key status by default.
private final class OnboardingPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Minimal `NSWindowDelegate` that fires a closure when the window closes,
/// letting `OnboardingWindowController` mark completion and drop its strong
/// reference so a future `show()` builds a fresh window.
@MainActor
private final class OnboardingCloseRelay: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
