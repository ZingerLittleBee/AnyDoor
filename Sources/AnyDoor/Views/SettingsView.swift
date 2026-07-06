import SwiftUI

struct SettingsView: View {
    @State private var opener = SettingsOpener.shared
    @State private var selectedTab: SettingsTab = .panel

    var body: some View {
        NavigationSplitView {
            // General is pinned to the sidebar's bottom edge, apart from the
            // feature sections. It lives in a bottom safe-area inset of the
            // one List — a second List would draw its own slice of the sidebar
            // card chrome and visibly break the card's outline at the seam.
            List(selection: $selectedTab) {
                ForEach(SettingsTab.allCases.filter { $0 != .general }, id: \.self) { tab in
                    sidebarRow(tab)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                generalRow
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .navigationSplitViewColumnWidth(160)
            // The sidebar is the window's whole navigation — collapsing it
            // would strand the user, so drop the toggle button.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView
                // An empty title suppresses the Settings scene's fallback
                // window title — the selected sidebar row already says where
                // you are. Hiding the toolbar background also drops the
                // hairline that appears over the detail column once content
                // scrolls under it.
                .navigationTitle("")
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

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        Label { LocalizedText(tab.titleKey) } icon: { Image(systemName: tab.systemImage) }
            .tag(tab)
    }

    /// The pinned General row. Not a List row (see the safe-area-inset comment
    /// above), so the sidebar-row look — insets, pill radius, accent selection
    /// fill — is reproduced by hand to match the rows in the List.
    private var generalRow: some View {
        let isSelected = selectedTab == .general
        return Button {
            selectedTab = .general
        } label: {
            Label { LocalizedText(SettingsTab.general.titleKey) } icon: { Image(systemName: SettingsTab.general.systemImage) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
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
