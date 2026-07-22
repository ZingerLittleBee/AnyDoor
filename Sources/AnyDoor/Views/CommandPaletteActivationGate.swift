import AppKit
import PluginInterface
import PluginSupport

/// Presents work only after AnyDoor has actually become the active application.
/// A global hotkey can summon the palette while this accessory app is in the
/// background; requesting activation and immediately keying the panel races the
/// workspace transition. Waiting for the notification keeps first-responder
/// assignment on the system's real activation boundary.
@MainActor
final class CommandPaletteActivationGate {
    private let notificationCenter: NotificationCenter
    private let notificationObject: AnyObject
    private let isActive: @MainActor () -> Bool
    private let requestActivation: @MainActor () -> Void

    private var observer: NSObjectProtocol?
    private var pendingPresentation: (@MainActor () -> Void)?

    convenience init(application: NSApplication = .shared) {
        self.init(
            notificationCenter: .default,
            notificationObject: application,
            isActive: { application.isActive },
            requestActivation: { application.activate(ignoringOtherApps: true) }
        )
    }

    init(
        notificationCenter: NotificationCenter,
        notificationObject: AnyObject,
        isActive: @escaping @MainActor () -> Bool,
        requestActivation: @escaping @MainActor () -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.notificationObject = notificationObject
        self.isActive = isActive
        self.requestActivation = requestActivation
    }

    var isWaiting: Bool { pendingPresentation != nil }

    func presentWhenActive(
        prepareForActivation: @MainActor () -> Void = {},
        _ presentation: @escaping @MainActor () -> Void
    ) {
        cancel()
        guard !isActive() else {
            presentation()
            return
        }

        pendingPresentation = presentation
        observer = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: notificationObject,
            queue: .main
        ) { [weak self] _ in
            MainThreadIsolation.run { self?.finishIfActive() }
        }

        // An accessory app needs an eligible visible window before AppKit will
        // complete activation. Show it without making it key, then wait for the
        // real activation boundary before assigning first responder.
        prepareForActivation()
        requestActivation()
        // Close the gap where activation completes between the initial state
        // check and observer registration without relying on an arbitrary delay.
        finishIfActive()
    }

    func cancel() {
        pendingPresentation = nil
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    private func finishIfActive() {
        guard isActive(), let presentation = pendingPresentation else { return }
        pendingPresentation = nil
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        presentation()
    }
}
