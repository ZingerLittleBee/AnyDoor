import SwiftUI
import AppKit

struct BindingEditView: View {
    var onSave: (KeyBinding) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var keyCode: Int = -1
    @State private var modifierFlags: Int = 0
    @State private var keyDisplay: String = "点击录入快捷键"
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    @State private var appName: String = ""
    @State private var appBundleID: String = ""
    @State private var appPath: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("添加快捷键绑定")
                .font(.headline)

            GroupBox("快捷键") {
                Button(keyDisplay) {
                    startRecording()
                }
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(isRecording ? Color.accentColor.opacity(0.2) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            GroupBox("目标应用") {
                HStack {
                    if appName.isEmpty {
                        Text("未选择应用")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(appName)
                    }
                    Spacer()
                    Button("选择...") {
                        pickApp()
                    }
                }
                .padding(4)
            }

            HStack {
                Button("取消") {
                    stopRecording()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("保存") {
                    stopRecording()
                    let binding = KeyBinding(
                        keyCode: keyCode,
                        modifierFlags: modifierFlags,
                        appBundleID: appBundleID,
                        appName: appName,
                        appPath: appPath
                    )
                    onSave(binding)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(keyCode < 0 || appBundleID.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        keyDisplay = "按下快捷键..."
        HotkeyService.shared.suspend()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            self.keyCode = Int(event.keyCode)
            // Use CGEvent modifier mask values to match the callback comparison
            let cgFlags = event.cgEvent?.flags ?? []
            let mask: UInt64 = CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskControl.rawValue
                | CGEventFlags.maskAlternate.rawValue
                | CGEventFlags.maskShift.rawValue
            self.modifierFlags = Int(cgFlags.rawValue & mask)

            var parts: [String] = []
            if event.modifierFlags.contains(.control) { parts.append("⌃") }
            if event.modifierFlags.contains(.option) { parts.append("⌥") }
            if event.modifierFlags.contains(.shift) { parts.append("⇧") }
            if event.modifierFlags.contains(.command) { parts.append("⌘") }
            parts.append(KeyCodeMap.name(for: self.keyCode))
            self.keyDisplay = parts.joined()
            self.isRecording = false
            self.stopRecording()

            return nil // consume the event
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
            HotkeyService.shared.resume()
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.title = "选择应用程序"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            appPath = url.path
            if let bundle = Bundle(url: url) {
                appBundleID = bundle.bundleIdentifier ?? ""
                appName = bundle.infoDictionary?["CFBundleName"] as? String
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
            }
        }
    }
}
