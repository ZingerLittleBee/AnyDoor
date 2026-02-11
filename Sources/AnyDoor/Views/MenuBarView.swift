import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Query(sort: \KeyBinding.createdAt) private var bindings: [KeyBinding]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            if bindings.isEmpty {
                Text("尚未配置快捷键")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(bindings) { binding in
                    HStack {
                        Text(binding.displayKey)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 80, alignment: .trailing)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Text(binding.appName)
                        Spacer()
                        Circle()
                            .fill(binding.isEnabled ? .green : .gray)
                            .frame(width: 8, height: 8)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
            }

            Divider()
                .padding(.vertical, 4)

            HStack {
                SettingsLink {
                    Label("设置", systemImage: "gear")
                }
                .buttonStyle(.plain)
                .onHover { _ in }
                .simultaneousGesture(TapGesture().onEnded {
                    NSApplication.shared.activate()
                })

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("退出", systemImage: "power")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .frame(width: 260)
    }
}
