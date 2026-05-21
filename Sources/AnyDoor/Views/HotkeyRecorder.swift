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

    @State private var instanceID = UUID()
    @State private var isRecording = false
    @State private var keyMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var fieldHovered = false

    var body: some View {
        // Outer is .onTapGesture (not Button) so the inner clear Button reliably
        // wins hit-test in its small area — nested Buttons have flaky tap routing
        // on macOS and the X would otherwise eat by the outer.
        ZStack(alignment: .trailing) {
            label
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { startRecording() }

            if hotkey != nil && !isRecording {
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
                .help("清除快捷键")
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
        .help(hotkey == nil ? "点击录入快捷键" : "点击重录 · ⌫ 清除 · ESC 取消")
        .onHover { fieldHovered = $0 }
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
            Text("按下快捷键…")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .italic()
        } else if let hk = hotkey {
            Text(hk.displayString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
        } else {
            Text("点击录入")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func startRecording() {
        // Tell the coordinator first so any sibling recorder stops cleanly
        // (it'll remove its monitor and reset isRecording) before we install ours.
        HotkeyRecordingCoordinator.shared.begin(id: instanceID) {
            stopRecording()
        }

        stopRecording(notifyCoordinator: false)
        isRecording = true
        HotkeyService.shared.suspend()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modMask: UInt64 = CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskControl.rawValue
                | CGEventFlags.maskAlternate.rawValue
                | CGEventFlags.maskShift.rawValue
            let cgFlags = event.cgEvent?.flags ?? []
            let mods = Int(cgFlags.rawValue & modMask)
            let code = Int(event.keyCode)

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

            let new = HotkeyDescriptor(keyCode: code, modifierFlags: mods)
            hotkey = new
            onChange(new)
            stopRecording()
            return nil
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
            HotkeyService.shared.resume()
        }
        if let cm = clickMonitor {
            NSEvent.removeMonitor(cm)
            clickMonitor = nil
        }
        isRecording = false
        if notifyCoordinator {
            HotkeyRecordingCoordinator.shared.end(id: instanceID)
        }
    }
}
