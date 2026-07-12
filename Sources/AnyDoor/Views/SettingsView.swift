import SwiftUI

/// Settings content: a fixed-width, non-collapsible sidebar on the left with
/// the pane list, and the selected pane on the right. Hosted by
/// `SettingsWindowController` in a manually managed, fixed-size NSWindow with
/// the same chrome as the Image Conversion window (`.fullSizeContentView` +
/// transparent titlebar), so the sidebar runs full height and wraps the
/// traffic lights at their standard position.
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
                .modifier(DetailNavigationTitle(selectedTab: selectedTab))
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
        .focusEffectDisabled()
    }

    /// Sidebar row: a flat monochrome-tinted symbol (no colored tile) + title.
    private func sidebarRow(_ tab: SettingsTab) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 15))
                .frame(width: 24, height: 24)
            LocalizedText(tab.titleKey)
        }
        .tag(tab)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .panel: PanelSettingsView()
        case .quicklinks: QuicklinksSettingsView()
        case .clipboard: ClipboardSettingsView()
        case .capture: CaptureSettingsView()
        case .translation: TranslationSettingsView()
        case .general: GeneralSettingsView()
        }
    }
}

/// Sets the detail's navigation title. On macOS 26 the toolbar shows no title
/// (dropped by `RemoveToolbarTitleOnTahoe`, matching Tahoe System Settings), so
/// a constant title is faithful and lossless. Earlier systems show the pane
/// name in the detail toolbar, like pre-26 System Settings.
private struct DetailNavigationTitle: ViewModifier {
    let selectedTab: SettingsTab

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.navigationTitle(Text(verbatim: "AnyDoor"))
        } else {
            content.navigationTitle(L(selectedTab.titleKey))
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
        case .quicklinks: .settingsTabQuicklinks
        case .clipboard: .settingsTabClipboard
        case .capture: .settingsTabCapture
        case .translation: .settingsTabTranslation
        case .general: .settingsTabGeneral
        }
    }

    var systemImage: String {
        switch self {
        case .panel: "rectangle.stack"
        case .quicklinks: "link"
        case .clipboard: "doc.on.clipboard"
        case .capture: "camera.viewfinder"
        case .translation: "character.bubble"
        case .general: "gear"
        }
    }
}
