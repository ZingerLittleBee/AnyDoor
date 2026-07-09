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
            // Clearance between the traffic lights (lowered to y=17 by
            // TrafficLightPosition) and the first row — without it the rows
            // start at ~33pt and collide with the lights.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 14)
            }
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
        .background(TrafficLightPosition())
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

/// Moves the traffic lights down and right into the sidebar card's header,
/// matching System Settings (its buttons sit at ~(18, 18) from the window's
/// top-left; the default title bar puts them at ~(8, 8), hugging the card's
/// corner). Only the three buttons' frame origins are translated. Do NOT grow
/// the title-bar container / title-bar view instead: the sidebar column lays
/// its glass card out below an internal NSTitlebarBackgroundView whose height
/// tracks the container, so a taller container pushes the card's top edge
/// below the buttons — exactly the wrap effect this window is built around.
/// (And never touch the window frame: that loops against the scene's sizing —
/// see the frame trick at the end of `SettingsView.body`.)
private struct TrafficLightPosition: NSViewRepresentable {
    /// Target distance from the window's top-left corner to the close
    /// button's top-left corner (measured from System Settings on macOS 26).
    private static let inset = CGPoint(x: 17, y: 17)
    /// The sidebar glass card's corner radius (the system default is 8).
    static let cardCornerRadius: CGFloat = 16

    func makeNSView(context: Context) -> TrackingView {
        TrackingView()
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {}

    final class TrackingView: NSView {
        // nonisolated(unsafe): only touched on the main thread — written in
        // viewDidMoveToWindow, read in deinit after all other refs are gone.
        private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { return }
            Self.layout(window)
            // AppKit re-lays the buttons out on these; win the last word.
            // (layout is a translation by the remaining delta, so re-applying
            // when already in place is a no-op.)
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { notification in
                    guard let window = notification.object as? NSWindow else { return }
                    // Same main-thread dance as RegularWindowCoordinator.
                    MainThreadIsolation.run { Self.layout(window) }
                }
            }
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        private static func applyCornerRadii(_ window: NSWindow) {
            guard #available(macOS 26.0, *) else { return }
            // The WINDOW's corner radius is intentionally left stock (16pt;
            // System Settings uses ~26.5pt). There is no public NSWindow API,
            // and every private route leaves the shape inconsistent or
            // crashes: the frame view's radius setter only rounds the content
            // (rim + shadow keep the old radius → notched corners), a
            // transparent window clipped in SwiftUI leaves the same rim and
            // shadow-hole artifacts, and a runtime subclass of the theme
            // frame overriding `_cornerRadius` trips AppKit's
            // NSDynamicProperties assertion at launch.
            //
            // Sidebar glass card: public NSGlassEffectView API.
            if let contentView = window.contentView,
               let card = findConcentricGlass(in: contentView) as? NSGlassEffectView,
               card.cornerRadius != TrafficLightPosition.cardCornerRadius {
                card.cornerRadius = TrafficLightPosition.cardCornerRadius
            }
        }

        private static func findConcentricGlass(in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("ConcentricGlassEffectView") { return view }
            for sub in view.subviews {
                if let hit = findConcentricGlass(in: sub) { return hit }
            }
            return nil
        }

        private static func layout(_ window: NSWindow) {
            // Only the close (red) button stays active; the miniaturize (yellow)
            // and zoom (green) buttons render disabled-gray. Dropping
            // .miniaturizable and .resizable from the mask greys them without
            // hiding them, matching a fixed-size utility Settings window. (The
            // scene pins the content size, so losing .resizable does not make
            // the window user-resizable anyway.)
            window.styleMask.remove([.miniaturizable, .resizable])
            applyCornerRadii(window)
            guard let close = window.standardWindowButton(.closeButton),
                  let superview = close.superview else { return }
            // Current distance from the window's top-left to the close
            // button's top-left, robust against superview flippedness.
            let currentTop = superview.isFlipped
                ? close.frame.minY
                : superview.bounds.height - close.frame.maxY
            let dx = TrafficLightPosition.inset.x - close.frame.minX
            let dTop = TrafficLightPosition.inset.y - currentTop
            guard dx != 0 || dTop != 0 else { return }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                var origin = button.frame.origin
                origin.x += dx
                origin.y += superview.isFlipped ? dTop : -dTop
                button.setFrameOrigin(origin)
            }
        }
    }
}

/// Sets the detail's navigation title, which also drives the window title.
///
/// On macOS 26 the title MUST stay constant across panes: varying it makes
/// AppKit relayout the titlebar and snap the traffic lights back to their
/// default origin on every tab switch (the lights are custom-positioned into
/// the sidebar card — see `TrafficLightPosition`). System Settings shows no
/// toolbar title on Tahoe anyway (we drop the item via `RemoveToolbarTitleOnTahoe`),
/// so a constant window title is faithful and lossless. Earlier systems show
/// the pane name in the detail toolbar, like pre-26 System Settings.
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
