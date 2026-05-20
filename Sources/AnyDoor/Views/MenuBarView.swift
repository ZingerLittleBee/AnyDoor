import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Query(sort: \KeyBinding.createdAt) private var bindings: [KeyBinding]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AnyDoor").font(.headline)
                Spacer()
                Text("\(bindings.count) 个绑定").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)

            // Placeholder for upcoming PanelRowView rewrite (Task 21)
            Text("面板重构中…").foregroundStyle(.secondary).padding()

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                SettingsLink { Label("设置", systemImage: "gear") }
                    .buttonStyle(.glass)
                    .simultaneousGesture(TapGesture().onEnded {
                        NSApplication.shared.activate()
                    })
                Button {
                    NSApplication.shared.terminate(nil)
                } label: { Label("退出", systemImage: "power") }
                    .buttonStyle(.glass)
                Spacer()
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
        .frame(width: 260).frame(minHeight: 400)
        .onAppear {
            Task { await PanelStore.shared.refreshAll() }
        }
    }
}
