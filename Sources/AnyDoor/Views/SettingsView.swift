import SwiftUI

struct SettingsView: View {
    @State private var opener = SettingsOpener.shared
    @State private var selectedTab: SettingsTab = .panel

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Label { LocalizedText(tab.titleKey) } icon: { Image(systemName: tab.systemImage) }
                        .tag(tab)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(160)
            // The sidebar is the window's whole navigation — collapsing it
            // would strand the user, so drop the toggle button.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView
                // No title: the selected sidebar row already says where you are.
                // Hiding the toolbar background also drops the hairline that
                // appears over the detail column once content scrolls under it.
                .toolbarBackground(.hidden, for: .windowToolbar)
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
        .frame(width: 680, height: 480)
        // Adopt .regular activation policy while Settings is open so the window
        // stays reachable (Dock / Cmd-Tab) instead of vanishing when the user
        // focuses another app.
        .background(RegularWindowRegistrar())
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .panel: PanelSettingsView()
        case .clipboard: ClipboardSettingsView()
        case .capture: CaptureSettingsView()
        case .translation: TranslationSettingsView()
        case .general: GeneralSettingsView()
        }
    }
}

private extension SettingsTab {
    var titleKey: L10n.Key {
        switch self {
        case .panel: .settingsTabPanel
        case .clipboard: .settingsTabClipboard
        case .capture: .settingsTabCapture
        case .translation: .settingsTabTranslation
        case .general: .settingsTabGeneral
        }
    }

    var systemImage: String {
        switch self {
        case .panel: "rectangle.stack"
        case .clipboard: "doc.on.clipboard"
        case .capture: "camera.viewfinder"
        case .translation: "character.bubble"
        case .general: "gear"
        }
    }
}
