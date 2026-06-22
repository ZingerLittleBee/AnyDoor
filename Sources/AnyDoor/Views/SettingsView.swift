import SwiftUI

struct SettingsView: View {
    @State private var opener = SettingsOpener.shared
    @State private var selectedTab: SettingsTab = .panel

    var body: some View {
        TabView(selection: $selectedTab) {
            PanelSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabPanel) } icon: { Image(systemName: "rectangle.stack") }
                }
                .tag(SettingsTab.panel)

            ClipboardSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabClipboard) } icon: { Image(systemName: "doc.on.clipboard") }
                }
                .tag(SettingsTab.clipboard)

            CaptureSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabCapture) } icon: { Image(systemName: "camera.viewfinder") }
                }
                .tag(SettingsTab.capture)

            TranslationSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabTranslation) } icon: { Image(systemName: "character.bubble") }
                }
                .tag(SettingsTab.translation)

            GeneralSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabGeneral) } icon: { Image(systemName: "gear") }
                }
                .tag(SettingsTab.general)
        }
        // Honor a deep-link request (e.g. the translation gear) then clear it so
        // a later plain open lands on the last-selected tab.
        .onChange(of: opener.desiredTab) { _, tab in
            guard let tab else { return }
            selectedTab = tab
            opener.desiredTab = nil
        }
        .onAppear {
            if let tab = opener.desiredTab {
                selectedTab = tab
                opener.desiredTab = nil
            }
        }
        .frame(width: 560, height: 480)
        // Adopt .regular activation policy while Settings is open so the window
        // stays reachable (Dock / Cmd-Tab) instead of vanishing when the user
        // focuses another app.
        .background(RegularWindowRegistrar())
    }
}
