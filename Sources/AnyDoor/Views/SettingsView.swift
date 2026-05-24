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
        }
        .frame(width: 560, height: 480)
    }
}
