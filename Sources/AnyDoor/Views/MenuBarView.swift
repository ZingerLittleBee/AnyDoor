import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Query(sort: \KeyBinding.createdAt) private var bindings: [KeyBinding]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Text("AnyDoor")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(bindings.filter(\.isEnabled).count) 个快捷键")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)

            // Bindings list
            if bindings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 24))
                        .foregroundStyle(.quaternary)
                    Text("尚未配置快捷键")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("点击下方「设置」添加")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(bindings) { binding in
                        BindingRow(binding: binding)
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer(minLength: 0)

            // Footer actions
            HStack(spacing: 8) {
                SettingsLink {
                    Label("设置", systemImage: "gear")
                }
                .buttonStyle(.glass)
                .simultaneousGesture(TapGesture().onEnded {
                    NSApplication.shared.activate()
                })

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("退出", systemImage: "power")
                }
                .buttonStyle(.glass)

                Spacer()
            }
            .focusEffectDisabled()
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(width: 260)
        .frame(minHeight: 120)
    }
}

private struct BindingRow: View {
    let binding: KeyBinding
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(binding.displayKey)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(binding.appName)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Circle()
                .fill(binding.isEnabled ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(
            .regular.interactive(),
            in: .rect(cornerRadius: 8)
        )
        .onHover { hovering in isHovered = hovering }
    }
}
