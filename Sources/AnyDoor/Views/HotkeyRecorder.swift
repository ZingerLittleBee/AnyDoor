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
    @State private var monitor: Any?
    @State private var fieldHovered = false

    var body: some View {
        // ZStack lets the record button (base) and the clear button (top-trailing)
        // be true siblings, so SwiftUI's hit-test routes each click to whichever
        // is visually on top at the click point. With `.overlay { Button }` on a
        // parent Button, the parent often eats the click before the overlay sees it.
        ZStack(alignment: .trailing) {
            Button(action: { startRecording() }) {
                label
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

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
        .padding(.horizontal, 8).padding(.vertical, 4)
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
        if let hk = hotkey {
            Text(hk.displayString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
        } else if isRecording {
            Text("按下快捷键…")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .italic()
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

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
    }

    private func stopRecording(notifyCoordinator: Bool = true) {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            HotkeyService.shared.resume()
        }
        isRecording = false
        if notifyCoordinator {
            HotkeyRecordingCoordinator.shared.end(id: instanceID)
        }
    }
}
