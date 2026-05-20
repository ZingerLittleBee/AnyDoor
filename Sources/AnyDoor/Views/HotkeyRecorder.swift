import SwiftUI
import AppKit

/// Inline hotkey recording field. Click to enter recording mode; press a combination
/// to capture; press ESC to cancel; press ⌫ (no modifiers) to clear.
///
/// While recording, HotkeyService is suspended so the in-progress combination doesn't
/// fire an existing binding.
struct HotkeyRecorder: View {
    @Binding var hotkey: HotkeyDescriptor?
    var onChange: (HotkeyDescriptor?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: { startRecording() }) {
            label
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isRecording ? Color.accentColor.opacity(0.25) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    @ViewBuilder
    private var label: some View {
        if let hk = hotkey {
            Text(hk.displayString).foregroundStyle(.primary)
        } else if isRecording {
            Text("按下快捷键…").foregroundStyle(.secondary).italic()
        } else {
            Text("点击录入").foregroundStyle(.secondary).italic()
        }
    }

    private func startRecording() {
        stopRecording()
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

    private func stopRecording() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
            HotkeyService.shared.resume()
        }
        isRecording = false
    }
}
