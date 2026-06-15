import SwiftUI
import AppKit

/// Process-wide coordinator so at most one HotkeyRecorder is in recording mode.
///
/// Without this, clicking a second recorder leaves the first one visually highlighted
/// AND with a live NSEvent monitor, so the next keystroke is captured by both — both
/// rows end up bound to the same combo.
@MainActor
final class HotkeyRecordingCoordinator {
    static let shared = HotkeyRecordingCoordinator()

    private var activeID: UUID?
    private var stopActive: (() -> Void)?

    func begin(id: UUID, stop: @escaping () -> Void) {
        if activeID != id, let stopActive { stopActive() }
        activeID = id
        stopActive = stop
    }

    func end(id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        stopActive = nil
    }
}

/// Inline hotkey recording field, styled like a TextField for visual continuity with
/// other settings inputs. Click anywhere on the field to enter recording mode; press a
/// combination to capture; press ESC to cancel; press ⌫ (no modifiers) while recording
/// to clear. Outside of recording, a trailing clear (×) button with confirmation also
/// removes the binding.
///
/// While recording, HotkeyService is suspended so the in-progress combination doesn't
/// fire an existing binding.
struct HotkeyRecorder: View {
    @Binding var hotkey: HotkeyDescriptor?
    var onChange: (HotkeyDescriptor?) -> Void
    /// Whether to show the inline clear (×) button next to the bound hotkey.
    /// Disable for entries where clearing makes no sense (e.g. an app shortcut
    /// without a hotkey has nothing to trigger it — delete the row instead).
    var allowsClear: Bool = true

    @State private var instanceID = UUID()
    @State private var isRecording = false
    @State private var keyMonitor: Any?
    @State private var keyUpMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var hyperHeld = false
    @State private var liveModifiers: Int = 0
    @State private var fieldHovered = false
    @State private var hyperKey = HyperKeyService.shared

    var body: some View {
        // HStack (not ZStack) so the clear Button and the label own disjoint hit
        // regions. Earlier ZStack overlay had the label's onTapGesture covering
        // the X area; macOS SwiftUI hit-routing then sometimes sent taps to the
        // label even when the X was visually on top, so clicks didn't clear.
        HStack(spacing: 0) {
            label
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { startRecording() }

            if allowsClear && hotkey != nil && !isRecording {
                Button {
                    hotkey = nil
                    onChange(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(fieldHovered ? .secondary : .tertiary)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .help(L(.hotkeyRecorderClear))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(isRecording ? 0.04 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(
                    isRecording ? Color.accentColor : Color.secondary.opacity(0.3),
                    lineWidth: isRecording ? 1.5 : 0.5
                )
        )
        .help(L(hotkey == nil ? .hotkeyRecorderTipUnbound : .hotkeyRecorderTipBound))
        .onHoverSafe { fieldHovered = $0 }
        .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private var label: some View {
        // Recording state takes priority so an already-bound field also shows
        // the prompt when the user clicks it to re-record.
        //
        // All three states share `.caption` monospaced font so the field height
        // stays uniform regardless of binding state — only color/italic differ.
        if isRecording {
            let liveGlyphs = liveModifierGlyphs()
            if liveGlyphs.isEmpty {
                LocalizedText(.hotkeyRecorderPrompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                Text(liveGlyphs)
                    .font(.callout.weight(.medium))
                    .tracking(1.5)
                    .foregroundStyle(.primary)
            }
        } else if let hk = hotkey {
            Text(hk.displayString(hyperFlags: hyperKey.hyperModifierFlags))
                .font(.callout.weight(.medium))
                .tracking(1.5)
                .foregroundStyle(.primary)
        } else {
            LocalizedText(.hotkeyRecorderPlaceholder)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    /// Renders the live modifier glyphs while recording. Returns "" when no
    /// modifiers are currently held — the caller then shows the static prompt.
    /// Hyper collapses to "✦" when either (a) the trigger key's keyDown reached
    /// us directly (hyperHeld) or (b) the synthesized hyper modifier mask is
    /// already present in the real flags stream.
    private func liveModifierGlyphs() -> String {
        let hyperFlags = hyperKey.hyperModifierFlags
        let effective = hyperHeld ? (liveModifiers | hyperFlags) : liveModifiers
        if hyperFlags != 0 && effective == hyperFlags {
            return "✦"
        }
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: UInt(effective))
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    private func startRecording() {
        // Tell the coordinator first so any sibling recorder stops cleanly
        // (it'll remove its monitor and reset isRecording) before we install ours.
        HotkeyRecordingCoordinator.shared.begin(id: instanceID) {
            stopRecording()
        }

        stopRecording(notifyCoordinator: false)
        isRecording = true
        // Route Hyper trigger detection through HotkeyService's tap — it's
        // the only path that reliably sees Caps-Lock-sourced F19. The tap
        // suppresses bound-hotkey dispatch while the observer is set, so
        // recording can't accidentally fire an existing binding.
        HotkeyService.shared.beginRecording { held in
            // Already on main; observer is dispatched via DispatchQueue.main.async.
            hyperHeld = held
        }

        let modMask: UInt64 = CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskShift.rawValue

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Read hyper state dynamically — isActive may flip during a long
            // recording session if the user toggles Hyper from a sibling
            // settings sheet (rare, but cheap to defend against).
            let virtualKey = hyperKey.virtualKeyCode
            let hyperFlags = hyperKey.hyperModifierFlags
            let cgFlags = event.cgEvent?.flags ?? []
            var mods = Int(cgFlags.rawValue & modMask)
            let code = Int(event.keyCode)

            // Trigger keyDown — treat as a modifier press, never commit.
            // Tap normally swallows this so the branch is a fallback for
            // setups where the tap is down.
            if virtualKey >= 0 && code == virtualKey {
                hyperHeld = true
                return nil
            }

            if code == 53 { // ESC
                stopRecording()
                return nil
            }
            if code == 51 && mods == 0 { // Delete with no modifiers → clear
                hotkey = nil
                onChange(nil)
                stopRecording()
                return nil
            }

            // Hyper acts like a modifier — fold its flags in if (a) the tap
            // currently reports the trigger held (authoritative, race-free),
            // (b) the local @State has it (covers tap-down fallback), or
            // (c) the synthesized hyper mask already rode the event flags.
            let tapHyperHeld = HotkeyService.shared.isHyperHeld
            if tapHyperHeld || hyperHeld
               || (hyperFlags != 0 && (mods & hyperFlags) == hyperFlags) {
                mods |= hyperFlags
            }

            let new = HotkeyDescriptor(keyCode: code, modifierFlags: mods)
            hotkey = new
            onChange(new)
            stopRecording()
            return nil
        }

        // Live preview of the currently-held modifiers so the field reflects
        // the combo as the user builds it, rather than only at commit time.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let cgFlags = event.cgEvent?.flags ?? []
            liveModifiers = Int(cgFlags.rawValue & modMask)
            return event
        }

        // Track virtual F-key release to reset hyperHeld; pass non-virtual keys through.
        // Same as keyDown: this is a fallback — tap normally drives hyperHeld
        // through the recording observer.
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            let virtualKey = hyperKey.virtualKeyCode
            if virtualKey >= 0 && Int(event.keyCode) == virtualKey {
                hyperHeld = false
                return nil
            }
            return event
        }

        // Any mouse click cancels recording. If the click lands on this same
        // field, the .onTapGesture re-invokes startRecording() right after —
        // net effect is "click outside cancels, click inside restarts cleanly".
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            stopRecording()
            return event
        }
    }

    private func stopRecording(notifyCoordinator: Bool = true) {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
            HotkeyService.shared.endRecording()
        }
        if let m = keyUpMonitor {
            NSEvent.removeMonitor(m)
            keyUpMonitor = nil
        }
        if let fm = flagsMonitor {
            NSEvent.removeMonitor(fm)
            flagsMonitor = nil
        }
        if let cm = clickMonitor {
            NSEvent.removeMonitor(cm)
            clickMonitor = nil
        }
        hyperHeld = false
        liveModifiers = 0
        isRecording = false
        if notifyCoordinator {
            HotkeyRecordingCoordinator.shared.end(id: instanceID)
        }
    }
}
