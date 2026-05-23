import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PanelSettingsView()
                .tabItem {
                    Label("面板", systemImage: "rectangle.stack")
                }

            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gear")
                }
        }
        .frame(width: 560, height: 480)
    }
}
