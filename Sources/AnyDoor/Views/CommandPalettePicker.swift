import SwiftUI
import AppKit
import PluginInterface

struct CommandPalettePicker: View {
    @Bindable var state: CommandPaletteState
    let onSelect: (PanelEntry) -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onRefreshRates: () -> Void
    /// Opens a markdown link tapped inside the Detail pane. The controller
    /// scheme-guards and dismisses (plugin-supplied URLs, ADR-0009).
    let onOpenDetailLink: (URL) -> Void
    /// Notifies the controller when the Detail level is entered/left so it can
    /// hide the overlaid AppKit search field (no text input in Detail) and
    /// restore focus on return.
    let onDetailActiveChange: (Bool) -> Void
    /// Notifies the controller after any navigation-position change (drill-in or
    /// pop) so it can re-anchor the overlaid AppKit search field below the new
    /// back header — or back at the top when returning to the root.
    let onLevelChange: () -> Void
    let registerSearchAnchor: (CommandPaletteSearchAnchorView, String, String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if state.isInDetail {
                // The Detail level replaces the root search chrome entirely: only
                // the back header and the rendered markdown occupy the surface, so
                // the search field, its placeholder/caret, and the root list can
                // neither show through nor accept stray input.
                backHeader
                Divider().opacity(0.4)
                detailView
            } else {
                // Argument-input mode carries its own search-field badge (Raycast
                // style), so only the options level shows the back header.
                if backHeaderTitle != nil { backHeader }

                searchField

                Divider().opacity(0.4)

                if state.flatEntries.isEmpty {
                    if let scope = state.activeDevToolScope {
                        scopeTips(for: scope)
                    } else {
                        emptyState
                    }
                } else if state.isAtRoot {
                    entryList
                } else {
                    optionList
                }

                if state.isCurrencyContext {
                    Divider().opacity(0.4)
                    footerBar
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Liquid Glass on macOS 26+; .thickMaterial on earlier systems.
        // Driving the whole palette from one surface keeps the search field,
        // rows, and section headers visually consistent.
        .adaptivePanelSurface(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if let pending = state.pendingConfirmation {
                confirmCard(pending.confirmation)
            }
        }
        // NSHostingView inherits the full-size panel's 32-point titlebar safe
        // area. Apply this outside the complete surface so the material and its
        // content expand together instead of moving only the inner stack.
        .ignoresSafeArea()
        .onChange(of: state.query) { _, _ in
            // Space trigger for the dev-tool scope badge (Tab is handled by the
            // window controller's key monitor). No-ops once a scope is active.
            state.absorbDevToolScopeIfNeeded()
            state.selectedIndex = 0
            state.refreshPortsIfNeeded()
        }
        .onChange(of: state.isInDetail) { _, inDetail in
            onDetailActiveChange(inDetail)
        }
        .onChange(of: state.navigationRevision) { _, _ in
            onLevelChange()
        }
        .focusEffectDisabled()
    }

    /// Raycast-style in-palette confirmation for a destructive action. The
    /// dimmed backdrop reads as modal; the window controller's key monitor maps
    /// Return → confirm and Esc → cancel while this is shown.
    private func confirmCard(_ confirmation: CommandPaletteConfirmation) -> some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { state.cancelConfirmation() }

            VStack(spacing: 14) {
                // Center the glyph across the full card width rather than its
                // intrinsic bounds — the triangle's left/right bearing otherwise
                // reads as slightly off-center. Tint matches the destructive
                // Kill button so the card has one coherent danger color.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                Text(confirmation.title)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                Text(confirmation.message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    confirmButton(L(.commandPaletteConfirmCancel), hintText: "Esc", tint: .secondary) {
                        state.cancelConfirmation()
                    }
                    confirmButton(confirmation.confirmLabel, hintSymbol: "return", tint: .red, action: onConfirm)
                }
                .padding(.top, 2)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .adaptivePanelSurface(cornerRadius: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 24, y: 8)
        }
    }

    private func confirmButton(_ title: String, hintText: String? = nil, hintSymbol: String? = nil,
                               tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                keyHint(text: hintText, symbol: hintSymbol)
            }
            .foregroundStyle(tint == .secondary ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint == .red ? Color.red.opacity(0.14) : Color.primary.opacity(0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A small key-cap badge. Uses an SF Symbol (e.g. `return`) when given one —
    /// raw glyphs like "↵" carry odd font metrics that sit high in the badge —
    /// and a fixed minimum box so text and symbol hints center identically.
    @ViewBuilder
    private func keyHint(text: String?, symbol: String?) -> some View {
        Group {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
            } else if let text {
                Text(text).font(.system(size: 11, design: .rounded))
            }
        }
        .frame(minWidth: 16, minHeight: 15)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.1)))
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            if let scope = state.activeDevToolScope {
                scopeBadge(scope.badgeLabel)
            } else if let badge = state.argumentBadge {
                scopeBadge(badge)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)
            }
            CommandPaletteSearchAnchor(
                text: state.query,
                placeholder: searchFieldPlaceholder,
                registerAnchor: registerSearchAnchor
            )
            .frame(maxWidth: .infinity)
            .frame(height: 27)
            Button {
                state.query = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(state.query.isEmpty ? 0 : 1)
            .allowsHitTesting(!state.query.isEmpty)
            .accessibilityHidden(state.query.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// Placeholder text: prompts for an argument or scoped conversion body when
    /// needed, otherwise the usual root / second-level search hint.
    private var searchFieldPlaceholder: String {
        if let title = state.argumentInputTitle {
            return title
        }
        if state.activeDevToolScope != nil {
            return L(.commandPaletteDevToolScopePlaceholder)
        }
        return L(state.isAtRoot ? .commandPaletteSearchPlaceholder : .commandPaletteOptionSearchPlaceholder)
    }

    /// The Raycast-style scope pill shown in place of the magnifying glass once a
    /// dev-tool keyword has been absorbed.
    private func scopeBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            )
            .fixedSize()
    }

    /// Raycast-style bottom chrome: the selected row's primary action on the left
    /// ("the footer title"), and an "更新汇率" refresh button on the right.
    private var footerBar: some View {
        HStack(spacing: 8) {
            if let entry = selectedEntry {
                // Clickable, like Raycast: running it performs the selected row's
                // primary action (copy / open / toggle / …), same as pressing Return.
                Button { onSelect(entry) } label: {
                    HStack(spacing: 6) {
                        Text(primaryActionTitle(for: entry))
                            .font(.system(size: 12, weight: .medium))
                        keyHint(text: nil, symbol: "return")
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(action: onRefreshRates) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                    LocalizedText(.commandPaletteFooterRefreshRates)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L(.commandPaletteFooterRefreshRates))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    /// The currently selected row, or nil when there is no selection.
    private var selectedEntry: PanelEntry? {
        let entries = state.flatEntries
        guard entries.indices.contains(state.selectedIndex) else { return nil }
        return entries[state.selectedIndex]
    }

    /// The primary action of `entry`, shown as the footer title (mirrors Raycast's
    /// "Open Command").
    private func primaryActionTitle(for entry: PanelEntry) -> String {
        switch entry.source {
        case .appShortcut, .installedApp, .quicklink, .quicklinkArgument:
            return L(.commandPaletteActionOpen)
        case .quicklinkTemplate:
            return L(.commandPaletteActionEnter)
        case .portRecord:
            return L(.commandPaletteActionQuit)
        case .calcResult, .devTool, .conversion:
            return L(.commandPaletteActionCopy)
        case .devToolScopeSuggestion:
            return L(.commandPaletteActionEnter)
        case .pluginRow(_, let descriptor):
            return descriptor.actionLabel ?? L(.commandPaletteActionSelect)
        case .paletteOption(let id):
            if state.option(id: id)?.role == .destructive { return L(.commandPaletteActionQuit) }
            return L(.commandPaletteActionSelect)
        case .builtin(let item):
            switch item.kind {
            case .toggle: return L(.commandPaletteActionToggle)
            case .action: return L(.commandPaletteActionRun)
            case .submenu, .brightnessControl: return L(.commandPaletteActionEnter)
            case .hiddenHotkey: return L(.commandPaletteActionSelect)
            }
        }
    }

    /// The back-header title for the second-level view, or nil at levels that
    /// carry no header (root, and the badge-bearing argument-input modes).
    private var backHeaderTitle: String? {
        switch state.level {
        case .options(let optionsLevel): return optionsLevel.parentTitle
        case .detail(let detail): return detail.title
        case .list(let listLevel): return listLevel.title
        case .root, .argumentInput, .pluginArgumentInput: return nil
        }
    }

    private var backHeader: some View {
        Button {
            state.popLevel()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                if let title = backHeaderTitle {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 2)
        .help(L(.commandPaletteOptionBack))
    }

    /// The pushed markdown Detail: a loading placeholder, the rendered markdown,
    /// or an inline error — parsed with the system markdown parser (no
    /// third-party renderer). SwiftUI view internals are untested per repo
    /// convention; the loading/error state transitions are pinned at the state
    /// layer.
    @ViewBuilder
    private var detailView: some View {
        switch state.detailState {
        case .loading:
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                LocalizedText(.commandPalettePluginRowLoading)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        case .loaded(_, let markdown):
            ScrollView {
                MarkdownBlocksView(blocks: MarkdownBlocks.blocks(from: markdown))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .overlayScrollers()
            }
            .frame(minHeight: 320, maxHeight: .infinity)
            // Markdown links open through the environment so the controller can
            // scheme-guard the plugin-supplied URL and dismiss the palette.
            .environment(\.openURL, OpenURLAction { url in
                onOpenDetailLink(url)
                return .handled
            })
        case .failed(_, let message):
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
            .padding(.horizontal, 40)
        case .none:
            EmptyView()
        }
    }

    private var optionList: some View {
        ScrollViewReader { proxy in
            let entries = state.flatEntries
            let selectedID: String? = entries.indices.contains(state.selectedIndex)
                ? entries[state.selectedIndex].id
                : nil
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        CommandPaletteRow(
                            entry: entry,
                            hyperFlags: state.hyperFlags,
                            isSelected: entry.id == selectedID,
                            option: optionForEntry(entry),
                            onSelect: { onSelect(entry) }
                        )
                        .id(entry.id)
                    }
                }
                .overlayScrollers()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
            .frame(minHeight: 320, maxHeight: .infinity)
            .onChange(of: state.selectedIndex) { _, newIndex in
                guard entries.indices.contains(newIndex) else { return }
                proxy.scrollTo(entries[newIndex].id)
            }
        }
    }

    /// Resolve the option backing a `.paletteOption` entry so the row can render
    /// its checkmark / destructive styling.
    private func optionForEntry(_ entry: PanelEntry) -> CommandPaletteOption? {
        guard case let .paletteOption(id) = entry.source else { return nil }
        return state.option(id: id)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            LocalizedText(.commandPaletteEmpty)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
    }

    /// Shown in place of the generic empty state while a dev-tool scope is active
    /// but nothing has been typed yet — a usage hint plus a worked example.
    private func scopeTips(for scope: DevToolScope) -> some View {
        let hint = Self.scopeHint(for: scope)
        return VStack(spacing: 10) {
            Spacer()
            Image(systemName: "hammer")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(scope.badgeLabel)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            LocalizedText(hint.key)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(hint.example)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    /// A localized one-line usage hint and a worked example for each scope.
    /// The example is data (not localized); the hint is a catalog key.
    static func scopeHint(for scope: DevToolScope) -> (key: L10n.Key, example: String) {
        switch scope {
        case .base64: return (.devToolTipBase64, "hello → aGVsbG8=")
        case .url: return (.devToolTipURL, "a b&c → a%20b%26c")
        case .md5: return (.devToolTipMD5, "abc → 900150983cd24fb0…")
        case .sha1: return (.devToolTipSHA1, "abc → a9993e364706816a…")
        case .sha256: return (.devToolTipSHA256, "abc → ba7816bf8f01cfea…")
        }
    }

    private var entryList: some View {
        ScrollViewReader { proxy in
            let entries = state.flatEntries
            let selectedID: String? = entries.indices.contains(state.selectedIndex)
                ? entries[state.selectedIndex].id
                : nil

            ScrollView {
                // Deliberately flat — no `Section`/`pinnedViews`. Wrapping the
                // rows in `Section` makes SwiftUI's lazy layout re-traverse the
                // whole sectioned view list on EVERY scroll-wheel event
                // (~6.5 ms per event at ~260 rows, debug and release alike),
                // which saturates the main thread under a 120 Hz trackpad
                // event stream and causes intermittent dropped frames. A flat
                // ForEach with inline header rows costs ~0.5 ms steady-state.
                // The trade-off: headers scroll away with the content instead
                // of pinning (Raycast behaves the same way). Do not reintroduce
                // Section here without re-running a scroll-cost measurement.
                LazyVStack(spacing: 0) {
                    // Sentinel at the very top of the scroll content: keyboard
                    // navigation scrolls here when the selection returns to
                    // row 0 so the first section header is brought into view
                    // (scrolling to the row itself would leave the header
                    // clipped above the viewport).
                    Color.clear
                        .frame(height: 0)
                        .id("top-sentinel")
                    ForEach(state.filteredSections) { section in
                        sectionHeader(titleKey: section.titleKey)
                        ForEach(section.entries) { entry in
                            CommandPaletteRow(
                                entry: entry,
                                hyperFlags: state.hyperFlags,
                                isSelected: entry.id == selectedID,
                                onSelect: { onSelect(entry) }
                            )
                            .id(entry.id)
                        }
                    }
                }
                .overlayScrollers()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 8) }
            .frame(minHeight: 320, maxHeight: .infinity)
            .onChange(of: state.selectedIndex) { _, newIndex in
                guard entries.indices.contains(newIndex) else { return }
                if newIndex == 0 {
                    // Top of list — scroll to the sentinel so the first
                    // section header is visible above row 0.
                    proxy.scrollTo("top-sentinel")
                } else {
                    proxy.scrollTo(entries[newIndex].id)
                }
            }
        }
    }

    private func sectionHeader(titleKey: String) -> some View {
        LocalizedText(raw: titleKey)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .tracking(0.6)
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommandPaletteRow: View {
    let entry: PanelEntry
    let hyperFlags: Int
    let isSelected: Bool
    var option: CommandPaletteOption? = nil
    let onSelect: () -> Void

    @State private var isHovering = false
    @State private var appIcon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: Self.iconSize, height: Self.iconSize)
            titleBlock
            Spacer()
            if let option, option.isChecked {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else if let hotkey = entry.hotkey {
                Text(hotkey.displayString(hyperFlags: hyperFlags))
                    .font(.system(size: 12, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHoverSafe { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .task(id: entry.id) {
            // Resolve the Finder icon via the shared cache. A warm path
            // (prewarmed apps, recycled rows) seeds synchronously with no
            // flash; a cold path resolves off the main thread, so the first
            // scroll into the Applications section never blocks on disk I/O.
            guard let path = iconPath else { return }
            if let cached = AppIconCache.cached(path) {
                appIcon = cached
            } else {
                appIcon = await AppIconCache.icon(for: path)
            }
        }
    }

    @ViewBuilder
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.localizedTitle())
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(option?.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .lineLimit(1)
            if showsSubtitle, let subtitle = entry.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let request = entry.quicklinkIcon {
            QuicklinkIconView(
                request: request,
                fallbackSymbol: entry.symbol,
                size: Self.iconSize,
                symbolPointSize: 13
            )
        } else if iconPath != nil {
            // App-backed row: render the cached icon loaded in `.task`. Never
            // resolve it inside `body` — see the .task comment above.
            Group {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Color.clear
                }
            }
        } else {
            // SF Symbols carry no built-in transparent padding, so they need a
            // smaller point size than the 22pt frame to read at the same visual
            // weight as NSImage app icons. Built-in toggles read at full
            // strength; other symbol rows match the dimmer fallback weight.
            //
            // A toggle in its on-state gets an accent-tinted badge behind the
            // glyph (mirroring the menu-bar panel's `iconBadge`), so the active
            // state is visible right on the icon without a trailing switch. The
            // glyph color itself never changes — only the badge tint does, like
            // the menu bar (whose symbol stays `.primary` on and off).
            Image(systemName: entry.symbol)
                .font(.system(size: 13))
                .foregroundStyle(isBuiltin ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .opticallyCentered(symbol: entry.symbol, pointSize: 13)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background {
                    if isToggleOn {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.22))
                    }
                }
        }
    }

    /// Side length of the leading icon slot / on-state badge. Kept at the
    /// original size so row height, alignment and the badge stay unchanged —
    /// only the glyph drawn inside it is smaller (the 13pt symbol above).
    private static let iconSize: CGFloat = 22

    /// True when this row is a toggle that is currently on. Drives the
    /// accent-tinted on-state badge behind the icon.
    private var isToggleOn: Bool {
        entry.kind == .toggle && entry.toggleState == true
    }

    /// File path whose Finder icon backs this row, or nil when the row draws an
    /// SF Symbol instead. App shortcuts and installed apps resolve a real icon;
    /// built-ins and port records use a symbol.
    private var iconPath: String? {
        switch entry.source {
        case .appShortcut:
            return PanelStore.shared.binding(id: bindingID).map(\.appPath)
        case .installedApp(_, let path):
            return path
        case .builtin, .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion, .paletteOption, .pluginRow, .quicklink, .quicklinkTemplate, .quicklinkArgument:
            return nil
        }
    }

    /// Port records, calculator results, dev-tool conversions, unit/time/currency
    /// conversions, plugin rows, and second-level options render their subtitle
    /// (the port detail line, the original expression for a calc result, the
    /// conversion source/rate-date for a conversion row, the tool name for a
    /// dev-tool row, a plugin row's declared subtitle, or a port option's detail).
    private var showsSubtitle: Bool {
        switch entry.source {
        case .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion, .paletteOption, .pluginRow, .quicklink, .quicklinkTemplate, .quicklinkArgument: return true
        default: return false
        }
    }

    private var isBuiltin: Bool {
        if case .builtin = entry.source { return true }
        return false
    }

    private var bindingID: UUID {
        if case .appShortcut(let id) = entry.source { return id }
        return UUID()
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.25)
        }
        if isHovering {
            return Color.primary.opacity(0.08)
        }
        return Color.clear
    }
}

/// Lays out `MarkdownBlocks` output as a modest styled document for the palette
/// Detail: headings, paragraphs, bulleted/numbered lists, code blocks,
/// thematic rules, blockquotes, and http(s) image previews. Deliberately not a
/// full renderer — inline styling (bold /
/// italic / inline-code / links) is carried by each block's `AttributedString`
/// and rendered by `Text`; block structure is what this view adds back.
private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(.system(size: Self.headingSize(level), weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 4 : 1)
        case .paragraph(let text):
            Text(text)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let ordinal, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ordinal.map { "\($0)." } ?? "•")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Text(text)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 6)
        case .codeBlock(let code):
            Text(code)
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        case .thematicBreak:
            Divider().opacity(0.5).padding(.vertical, 2)
        case .blockquote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 1)
        case .image(let url):
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                case .failure:
                    // Keep the information reachable when loading fails: a
                    // tappable link in place of the preview.
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "photo")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                case .empty:
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 120)
                        .overlay(ProgressView().controlSize(.small))
                @unknown default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 280, alignment: .leading)
        }
    }

    /// Heading point sizes, tapering h1→h6 down toward body size (14pt).
    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 18
        case 3: return 16
        case 4: return 15
        default: return 14
        }
    }
}
