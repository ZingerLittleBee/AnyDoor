import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PanelSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabPanel) } icon: { Image(systemName: "rectangle.stack") }
                }

            GeneralSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabGeneral) } icon: { Image(systemName: "gear") }
                }

            SyncSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabSync) } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                }
        }
        .frame(width: 560, height: 480)
    }
}
