import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            PanelSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabPanel) } icon: { Image(systemName: "rectangle.stack") }
                }

            ClipboardSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabClipboard) } icon: { Image(systemName: "doc.on.clipboard") }
                }

            CaptureSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabCapture) } icon: { Image(systemName: "camera.viewfinder") }
                }

            TranslationSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabTranslation) } icon: { Image(systemName: "character.bubble") }
                }

            GeneralSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabGeneral) } icon: { Image(systemName: "gear") }
                }
        }
        .frame(width: 560, height: 480)
        // Adopt .regular activation policy while Settings is open so the window
        // stays reachable (Dock / Cmd-Tab) instead of vanishing when the user
        // focuses another app.
        .background(RegularWindowRegistrar())
    }
}
