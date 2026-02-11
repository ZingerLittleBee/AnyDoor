import SwiftUI
import SwiftData

struct BindingListView: View {
    @Query(sort: \KeyBinding.createdAt) private var bindings: [KeyBinding]
    @Environment(\.modelContext) private var modelContext
    @State private var selection: KeyBinding?
    @State private var showingEditor = false

    var body: some View {
        VStack {
            List(selection: $selection) {
                ForEach(bindings) { binding in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Bindable(binding).isEnabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                        Text(binding.displayKey)
                            .font(.system(.body, design: .monospaced))

                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)

                        Text(binding.appName)

                        Spacer()
                    }
                    .tag(binding)
                    .padding(.vertical, 2)
                }
            }

            HStack(spacing: 6) {
                Button {
                    showingEditor = true
                    selection = nil
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 22)
                }
                .buttonStyle(.bordered)

                Button {
                    if let selected = selection {
                        modelContext.delete(selected)
                        try? modelContext.save()
                        selection = nil
                        Self.refreshHotkeyService()
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 22)
                }
                .buttonStyle(.bordered)
                .disabled(selection == nil)

                Spacer()
            }
            .padding(8)
        }
        .sheet(isPresented: $showingEditor) {
            BindingEditView { newBinding in
                modelContext.insert(newBinding)
                try? modelContext.save()
                Self.refreshHotkeyService()
            }
        }
        .onChange(of: bindings.map(\.isEnabled)) {
            try? modelContext.save()
            Self.refreshHotkeyService()
        }
    }

    private static func refreshHotkeyService() {
        if let delegate = NSApplication.shared.delegate as? AppDelegate {
            delegate.refreshBindings()
        }
    }
}
