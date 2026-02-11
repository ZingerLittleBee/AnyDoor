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

            HStack {
                Button {
                    showingEditor = true
                    selection = nil
                } label: {
                    Image(systemName: "plus")
                }

                Button {
                    if let selected = selection {
                        modelContext.delete(selected)
                        try? modelContext.save()
                        selection = nil
                        notifyBindingsChanged()
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)

                Spacer()
            }
            .padding(8)
        }
        .sheet(isPresented: $showingEditor) {
            BindingEditView { newBinding in
                modelContext.insert(newBinding)
                try? modelContext.save()
                notifyBindingsChanged()
            }
        }
    }

    private func notifyBindingsChanged() {
        if let delegate = NSApplication.shared.delegate as? AppDelegate {
            delegate.refreshBindings()
        }
    }
}
