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
                    HStack {
                        Toggle("", isOn: Bindable(binding).isEnabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()

                        Text(binding.displayKey)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 100, alignment: .trailing)

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
                        HotkeyService.shared.updateBindings(bindings.filter { $0.id != selected.id })
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
                HotkeyService.shared.updateBindings(bindings + [newBinding])
            }
        }
        .onChange(of: bindings.map(\.isEnabled)) {
            try? modelContext.save()
            HotkeyService.shared.updateBindings(bindings)
        }
    }
}
