import SwiftUI

/// System Settings-style Settings window: a fixed-width, non-collapsible
/// sidebar on the left with the traffic lights sitting inside the sidebar
/// column, and the selected pane on the right. On macOS 26 the sidebar renders
/// as the floating Liquid Glass card; earlier systems fall back to the classic
/// full-height sidebar material (the Ventura–Sequoia System Settings look).
struct SettingsView: View {
    @State private var opener = SettingsOpener.shared
    @State private var selectedTab: SettingsTab = .panel

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    sidebarRow(tab)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(180)
            // The sidebar is the window's whole navigation — collapsing it
            // would strand the user, so drop the toggle button.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detailView
                // The pane name, like pre-26 System Settings shows in its
                // detail toolbar. On macOS 26 System Settings shows no toolbar
                // title, so remove the item there — but keep the title set:
                // it still names the window (Window menu, accessibility).
                .navigationTitle(L(selectedTab.titleKey))
                .modifier(RemoveToolbarTitleOnTahoe())
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
        // Fixed width, flexible height: the window stays vertically resizable
        // like System Settings.
        .frame(width: 680)
        .frame(minHeight: 480, idealHeight: 480)
        // Adopt .regular activation policy while Settings is open so the window
        // stays reachable (Dock / Cmd-Tab) instead of vanishing when the user
        // focuses another app.
        .background(RegularWindowRegistrar())
        .focusEffectDisabled()
    }

    /// System Settings-style row: a small colored icon tile + title.
    private func sidebarRow(_ tab: SettingsTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tab.iconColor.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            LocalizedText(tab.titleKey)
        }
        .tag(tab)
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

/// Drops the toolbar title item on macOS 26, matching Tahoe System Settings.
/// Do NOT reach for `.navigationTitle("")` or `.toolbarBackground(.hidden)`
/// instead: both collapse the unified toolbar, which pushes the whole split
/// view below the title-bar region and strands the traffic lights on a bare
/// strip above the sidebar card.
private struct RemoveToolbarTitleOnTahoe: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .toolbar(removing: .title)
                // Also drop the toolbar's background so the hairline over the
                // detail column disappears, like Tahoe System Settings. Note
                // this is the macOS 26 `toolbarBackgroundVisibility`, NOT the
                // older `toolbarBackground(.hidden,)` — see above.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
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

    var iconColor: Color {
        switch self {
        case .panel: .blue
        case .clipboard: .orange
        case .capture: .purple
        case .translation: .teal
        case .general: .gray
        }
    }
}
