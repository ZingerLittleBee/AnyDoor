import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("快捷键", systemImage: "keyboard") {
                BindingListView()
            }
            Tab("通用", systemImage: "gear") {
                GeneralSettingsView()
            }
        }
        .frame(width: 520, height: 380)
    }
}
