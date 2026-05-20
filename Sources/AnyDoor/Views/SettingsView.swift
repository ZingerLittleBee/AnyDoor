import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("面板", systemImage: "rectangle.stack") {
                PanelSettingsView()
            }
            Tab("通用", systemImage: "gear") {
                GeneralSettingsView()
            }
        }
        .frame(width: 560, height: 480)
    }
}
