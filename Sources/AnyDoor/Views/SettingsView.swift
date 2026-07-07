import SwiftUI

/// System Settings-style Settings window: a fixed-width, non-collapsible
/// sidebar on the left with the traffic lights sitting inside the sidebar
/// column, and the selected pane on the right. On macOS 26 the sidebar renders
/// as the floating Liquid Glass card; earlier systems fall back to the classic
/// full-height sidebar material (the Ventura–Sequoia System Settings look).
struct SettingsView: View {
    @State private var opener = SettingsOpener.shared
    @State private var selectedTab: SettingsTab = .panel

    /// Full window height, title-bar region included — the root view spans the
    /// whole window (see the frame trick at the end of `body`).
    static let contentHeight: CGFloat = 512
    /// The extra height the Settings scene adds to the reported layout height
    /// when sizing its window — the hidden title bar's region.
    static let titleBarAccommodation: CGFloat = 32

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    sidebarRow(tab)
                }
            }
            .listStyle(.sidebar)
            // Taller card header: System Settings starts the sidebar content
            // ~63pt below the window top (measured), giving the traffic
            // lights a roomier header zone than the split view's built-in
            // ~48pt toolbar clearance provides.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 14)
            }
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
        // System Settings-style chrome, part 2 (part 1 is the scene-level
        // .hiddenTitleBar): the sidebar's glass card must reach the window's
        // top edge and WRAP the traffic lights. SwiftUI fights this two ways:
        // the scene always sizes the window to the root's layout height PLUS a
        // 32pt title-bar accommodation, and it lays the root out below that
        // region (ignoresSafeArea is a dead end: a flexible root just clamps
        // to the safe-area proposal, a fixed root leaves a 32pt dead band at
        // the bottom, and correcting the window frame from AppKit loops
        // against NSHostingView.updateAnimatedWindowSize until AppKit throws).
        //
        // So render taller than we report: the inner frame is the real size —
        // the full window, title bar included — and the outer frame reports a
        // layout height 32pt shorter, so the scene opens the window at exactly
        // contentHeight. Bottom alignment makes the overflow stick out the
        // TOP, covering the title-bar region (SwiftUI doesn't clip frames).
        .frame(width: 680, height: Self.contentHeight)
        .frame(height: Self.contentHeight - Self.titleBarAccommodation, alignment: .bottom)
        // Adopt .regular activation policy while Settings is open so the window
        // stays reachable (Dock / Cmd-Tab) instead of vanishing when the user
        // focuses another app.
        .background(RegularWindowRegistrar())
        .background(TrafficLightLayout(headerHeight: 52))
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

/// Lowers the traffic lights into the sidebar card's header, System
/// Settings-style: the standard title bar centers them ~16pt down, hugging the
/// card's top edge, while System Settings centers them in a taller (~52pt)
/// header row. There is no public knob for this (`toolbarStyle = .unified` is
/// ignored in hiddenTitleBar windows), so this uses the same technique as
/// Electron's `trafficLightPosition`: grow the title-bar container view and
/// re-center the three buttons inside it, re-applying whenever AppKit re-lays
/// the title bar out. Only subview frames are touched — never the window
/// frame, which would loop against the scene's sizing (see the frame trick at
/// the end of `SettingsView.body`).
private struct TrafficLightLayout: NSViewRepresentable {
    let headerHeight: CGFloat

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.headerHeight = headerHeight
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.headerHeight = headerHeight
    }

    final class TrackingView: NSView {
        var headerHeight: CGFloat = 52

        // nonisolated(unsafe): only touched on the main thread — written in
        // viewDidMoveToWindow, read in deinit after all other refs are gone.
        private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { return }
            layout(window)
            // AppKit re-lays the title bar out on these; win the last word.
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] notification in
                    guard let window = notification.object as? NSWindow else { return }
                    // Same main-thread dance as RegularWindowCoordinator.
                    MainThreadIsolation.run { self?.layout(window) }
                }
            }
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        private func layout(_ window: NSWindow) {
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            guard let titlebarView = window.standardWindowButton(.closeButton)?.superview,
                  let container = titlebarView.superview else { return }

            // Grow the title-bar container downward from the window's top edge
            // so the lowered buttons stay inside it (hit-testing is bounded by
            // the container's frame).
            var containerFrame = container.frame
            containerFrame.origin.y = window.frame.height - headerHeight
            containerFrame.size.height = headerHeight
            container.frame = containerFrame

            var titlebarFrame = titlebarView.frame
            titlebarFrame.size.height = headerHeight
            titlebarFrame.origin.y = 0
            titlebarView.frame = titlebarFrame

            for type in buttons {
                guard let button = window.standardWindowButton(type) else { continue }
                var frame = button.frame
                frame.origin.y = (headerHeight - frame.height) / 2
                button.setFrameOrigin(frame.origin)
            }
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
