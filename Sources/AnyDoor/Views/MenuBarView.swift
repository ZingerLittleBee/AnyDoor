import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Query(sort: \KeyBinding.createdAt) private var bindings: [KeyBinding]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 8)

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
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 2) {
                    ForEach(bindings) { binding in
                        BindingRow(binding: binding)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Divider()
                .padding(.horizontal, 8)

            // Footer actions
            HStack(spacing: 12) {
                SettingsLink {
                    Label("设置", systemImage: "gear")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    NSApplication.shared.activate()
                })

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("退出", systemImage: "power")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 280)
        .frame(minHeight: 140)
    }
}

private struct BindingRow: View {
    let binding: KeyBinding
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Text(binding.displayKey)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(minWidth: 60, alignment: .trailing)

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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { hovering in isHovered = hovering }
    }
}
