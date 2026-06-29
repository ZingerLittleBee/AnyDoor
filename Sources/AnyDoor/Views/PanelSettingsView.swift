import SwiftUI
import AppKit

struct PanelSettingsView: View {
    @State private var panel = PanelStore.shared
    @State private var grouping = PanelGroupingStore.shared
    @State private var conflictAlert: ConflictAlert?
    @State private var pendingDelete: PendingDelete?

    /// Live frame of every row in the `listSpace` coordinate space, fed by a
    /// preference. Measured in the *content* space so it stays put while
    /// scrolling (only a layout change re-emits it) — the drag projection and
    /// the insertion indicator read it.
    @State private var rowFrames: [String: CGRect] = [:]
    /// The in-flight reorder drag, or nil. Local `@State` (not the `@Observable`
    /// store) so `withAnimation` captures the lift/settle cleanly.
    @State private var drag: DragSession?

    /// Edit mode. Transient (resets when the window closes): reveals the per-row
    /// visibility checkbox and drag handle. Out of edit mode the list reads as a
    /// clean reference view — hidden items still convey their state via dimming.
    /// Changes apply live; there is no separate save step.
    @State private var isEditing = false

    /// Spring for entering/leaving edit mode — drives the leading columns sliding
    /// in and the content reflowing right in lockstep.
    private static let editAnimation: Animation = .smooth(duration: 0.28)

    /// Named coordinate space the row frames and the drag gesture share.
    private static let listSpace = "panelSettingsList"

    /// Width of the disclosure-chevron column. Doubles as the parent-row toggle's
    /// hit-target width — wide enough to click comfortably, and shared by the
    /// header chevron and the spacer that stands in for it so every row's columns
    /// stay aligned.
    private static let disclosureColumnWidth: CGFloat = 20

    /// Width of the drag-handle column — wide enough, together with the full row
    /// height, to give the grab handle a comfortable drag/hover target instead of
    /// the bare glyph.
    private static let handleColumnWidth: CGFloat = 24

    /// Shared easing for collapse/expand and drop-settle: drives the row
    /// transition, the reorder slide, and the disclosure chevron rotation so
    /// they move in lockstep. `.smooth` is a non-overshooting spring that fits a
    /// settling list better than a bouncy one.
    private static let collapseAnimation: Animation = .smooth(duration: 0.24)

    var body: some View {
        VStack(spacing: 0) {
            editModeHeader
            ScrollView {
                // The List → ScrollView migration. Rows render in a plain VStack
                // (not a List) so collapse/expand and reorder animate: macOS
                // `List` is NSTableView-backed and ignores row insert/delete and
                // move animations even under a live transaction (the chevron
                // animates, the rows do not). A plain VStack — not LazyVStack —
                // keeps every row in the tree so its transition is reliable and
                // scrolling never rebuilds a row (the bounded row count makes
                // eager layout cheap, and it drops the NSTableView cell-recycling
                // that made scrolling janky). Reordering is a custom drag gesture
                // on each row's handle (see `dragGesture`), since `.onMove` only
                // works inside a List.
                VStack(spacing: 0) {
                    ForEach(displayRows) { row in
                        let dragging = drag?.rowID == row.id
                        rowView(row)
                            .opacity(row.opacity)
                            // Per-row frame probes feed the drag's drop-index math,
                            // which only runs in edit mode. Gating them here keeps
                            // the resting (non-edit) list free of ~40 GeometryReader
                            // layout passes — entering edit mode attaches them
                            // before any drag can start, so frames are ready in time.
                            .background { if isEditing { rowFrameReader(row) } }
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.accentColor.opacity(dragging ? 0.10 : 0))
                            )
                            .scaleEffect(dragging ? 1.01 : 1)
                            .shadow(color: .black.opacity(dragging ? 0.16 : 0),
                                    radius: dragging ? 5 : 0, y: 2)
                            .zIndex(dragging ? 1 : 0)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(name: Self.listSpace)
                .overlay(alignment: .topLeading) { insertionIndicator }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                // Trailing breathing room so the last row never butts against the
                // window's bottom edge (the tip footer only shows in edit mode).
                .padding(.bottom, 12)
                // One value-keyed animation for every structural change: collapse
                // (ids added/removed, with the row `.transition`) and drop-settle
                // (ids reordered, rows slide). A visibility toggle leaves the id
                // list unchanged, so it stays instant.
                .animation(Self.collapseAnimation, value: rowsKey)
                .overlayScrollers()
                .onPreferenceChange(RowFrameKey.self) { frames in
                    MainThreadIsolation.run { rowFrames = frames }
                }
            }
            // Don't clip the lifted (scaled, shadowed) dragged row at the scroll
            // edges.
            .scrollClipDisabled()
            // Warm the icon cache for every app-shortcut path off the main
            // thread when the list appears (and whenever the set changes), so
            // the first scroll past an app row finds a resolved icon instead of
            // a cold-cache disk hit. Re-keyed on count so add/remove re-warms.
            .task(id: panel.appShortcutPaths.count) {
                AppIconCache.prewarm(Array(panel.appShortcutPaths.values))
            }

            // The tip describes edit-only affordances (hiding via the checkbox,
            // adding/removing app shortcuts), so it appears only in edit mode
            // rather than as a permanent footer — keeping the resting view clean.
            if isEditing {
                LocalizedText(.settingsPanelTip)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .alert(item: $conflictAlert) { alert in
            Alert(
                title: Text(L(.settingsPanelHotkeyConflictTitle)),
                message: Text(L(.settingsPanelHotkeyConflictMessage, alert.hotkey.displayString(hyperFlags: HyperKeyService.shared.hyperModifierFlags), alert.existingTitle)),
                primaryButton: .default(Text(L(.settingsPanelHotkeyConflictReplace))) {
                    alert.onReplace()
                },
                secondaryButton: .cancel(Text(L(.settingsPanelCancel)))
            )
        }
        .alert(item: $pendingDelete) { item in
            Alert(
                title: Text(L(.settingsPanelDeleteTitle, item.appName)),
                message: Text(L(.settingsPanelDeleteMessage)),
                primaryButton: .destructive(Text(L(.settingsPanelDeleteConfirm))) {
                    PanelStore.shared.deleteAppShortcut(id: item.bindingID)
                },
                secondaryButton: .cancel(Text(L(.settingsPanelCancel)))
            )
        }
    }

    /// A top header (below the window's tab bar, so it never overlaps it) holding
    /// the edit-mode toggle, right-aligned. Mirrors SwiftUI's `EditButton`
    /// convention (which is iOS-only): a borderless text button that swaps between
    /// "编辑" and "完成".
    private var editModeHeader: some View {
        HStack {
            Spacer()
            Button {
                withAnimation(Self.editAnimation) { isEditing.toggle() }
            } label: {
                LocalizedText(isEditing ? .settingsPanelEditDone : .settingsPanelEdit)
                    .font(.body)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .hoverCursor(.pointingHand)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// The ordered row-id list; the trigger for the structural animation.
    /// Reordering or collapsing changes it (animated); a visibility toggle keeps
    /// the same ids (instant).
    private var rowsKey: [String] {
        displayRows.map(\.id)
    }

    private var displayRows: [PanelSettingsRow] {
        PanelSettingsRowBuilder.build(
            topLevel: panel.topLevelEntries,
            appChildren: panel.appShortcutChildren,
            windowChildren: panel.windowLayoutChildren,
            collapsedParents: grouping.collapsedParents
        )
    }

    @ViewBuilder
    private func rowView(_ row: PanelSettingsRow) -> some View {
        switch row.content {
        case let .entry(entry):
            switch row.group {
            case .appChild:    appChildRow(entry, row: row)
            case .windowChild: windowChildRow(entry, row: row)
            default:           mainRow(entry, row: row)
            }
        case .addApp:
            addAppButton()
        case .brightnessRecorders:
            brightnessHotkeyRecorders()
        }
    }

    @ViewBuilder
    private func brightnessHotkeyRecorders() -> some View {
        VStack(spacing: 6) {
            brightnessHotkeyRow(item: .brightnessUp, labelKey: .builtinBrightnessUp)
            brightnessHotkeyRow(item: .brightnessDown, labelKey: .builtinBrightnessDown)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func brightnessHotkeyRow(item: BuiltinItem, labelKey: L10n.Key) -> some View {
        HStack(spacing: 8) {
            // Mirror the app-shortcut child row's leading columns so the label
            // lines up with the parent "屏幕亮度" title — which sits after the
            // handle, checkbox, and symbol columns. A child accent bar, a
            // handle-width spacer (these fixed rows aren't draggable), then
            // invisible checkbox + symbol columns. The checkbox placeholder is a
            // plain clear spacer matching PanelCheckbox's width.
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2).padding(.leading, 16)
            if isEditing {
                // These rows aren't draggable; the spacers only reserve the
                // handle + checkbox columns so the label stays aligned under the
                // parent "屏幕亮度" title while in edit mode.
                Color.clear.frame(width: Self.handleColumnWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Color.clear.frame(width: PanelCheckbox.width)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Color.clear.frame(width: 18)
            LocalizedText(labelKey).font(.caption).foregroundStyle(.secondary)
            Spacer()
            HotkeyRecorder(hotkey: .constant(PanelStore.shared.hotkeyForBuiltin(item))) { newValue in
                handleBrightnessHotkeyChange(item: item, newValue: newValue)
            }
            .frame(width: 150, alignment: .trailing)
            // Trailing inset matches the Window Layout sub-row so both columns
            // of recorders align flush along the panel's right edge.
            Color.clear.frame(width: 20)
        }
        .padding(.vertical, 3)
    }

    private func handleBrightnessHotkeyChange(item: BuiltinItem, newValue: HotkeyDescriptor?) {
        if let new = newValue,
           let existing = PanelStore.shared.entryUsingHotkey(new, excluding: .builtin(item)) {
            conflictAlert = ConflictAlert(
                hotkey: new,
                existingTitle: existing.title,
                onReplace: {
                    if case let .builtin(other) = existing.source {
                        PanelStore.shared.setBuiltinHotkey(other, hotkey: nil)
                    } else if case let .appShortcut(id) = existing.source {
                        PanelStore.shared.updateAppShortcut(id: id, hotkey: nil)
                    }
                    PanelStore.shared.setBuiltinHotkey(item, hotkey: new)
                }
            )
        } else {
            PanelStore.shared.setBuiltinHotkey(item, hotkey: newValue)
        }
    }

    private func mainRow(_ entry: PanelEntry, row: PanelSettingsRow) -> some View {
        HStack(spacing: 8) {
            if isEditing {
                dragHandle(for: row)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            parentDisclosure(for: entry)
            if isEditing {
                PanelCheckbox(isOn: Binding(
                    get: { entry.isVisible },
                    set: { newValue in
                        if case let .builtin(item) = entry.source {
                            panel.setBuiltinVisibility(item, isVisible: newValue)
                        }
                    }
                ))
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Image(systemName: entry.symbol).frame(width: 16)
            Text(entry.localizedTitle()).font(.body)
            LocalizedText(typeBadge(for: entry)).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            hotkeyField(for: entry)
            deleteButton(for: entry)
        }
        .padding(.vertical, 4)
    }

    /// A collapse chevron for parent rows that own children (`appShortcuts`,
    /// `windowLayout`). Other rows get an equal-width spacer so columns align.
    @ViewBuilder
    private func parentDisclosure(for entry: PanelEntry) -> some View {
        if case let .builtin(item) = entry.source, item == .appShortcuts || item == .windowLayout || item == .brightness {
            let collapsed = grouping.isParentCollapsed(item)
            Button {
                grouping.setParentCollapsed(item, !collapsed)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .animation(Self.collapseAnimation, value: collapsed)
                    // Grow the hit target from the bare glyph to the full column
                    // width and row height.
                    .frame(width: Self.disclosureColumnWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverCursor(.pointingHand)
        } else {
            Color.clear.frame(width: Self.disclosureColumnWidth)
        }
    }

    private func typeBadge(for entry: PanelEntry) -> L10n.Key {
        switch entry.kind {
        case .toggle:            return .settingsPanelTypeBadgeToggle
        case .action:            return .settingsPanelTypeBadgeAction
        case .submenu:           return .settingsPanelTypeBadgeSubmenu
        case .brightnessControl: return .settingsPanelTypeBadgeBrightness
        case .hiddenHotkey:      return .settingsPanelTypeBadgeHiddenHotkey
        }
    }

    @ViewBuilder
    private func hotkeyField(for entry: PanelEntry) -> some View {
        // Items that do not get a row-level hotkey recorder:
        //   - .submenu: opened by hover (children carry their own hotkeys)
        //   - .brightnessControl: bumps are bound inline below the row
        //   - .hiddenHotkey: never rendered in the settings grid
        if case let .builtin(item) = entry.source,
           item.kind == .submenu || item.kind == .brightnessControl || item.kind == .hiddenHotkey {
            Color.clear.frame(width: 150)
        } else {
            HotkeyRecorder(hotkey: .constant(entry.hotkey)) { newValue in
                handleHotkeyChange(entry: entry, newValue: newValue)
            }
            .frame(width: 150, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func deleteButton(for entry: PanelEntry) -> some View {
        if case let .appShortcut(id) = entry.source {
            Button {
                pendingDelete = PendingDelete(bindingID: id, appName: entry.localizedTitle())
            } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .help(L(.settingsPanelDeleteItemHelp, entry.localizedTitle()))
            .hoverCursor(.pointingHand)
        } else {
            // Reserve the same width so other columns stay aligned across rows.
            Color.clear.frame(width: 20)
        }
    }

    private func handleHotkeyChange(entry: PanelEntry, newValue: HotkeyDescriptor?) {
        if let new = newValue,
           let existing = panel.entryUsingHotkey(new, excluding: entry.source) {
            conflictAlert = ConflictAlert(
                hotkey: new,
                existingTitle: existing.localizedTitle(),
                onReplace: {
                    clearHotkey(for: existing.source)
                    apply(hotkey: new, to: entry)
                }
            )
        } else {
            apply(hotkey: newValue, to: entry)
        }
    }

    private func apply(hotkey: HotkeyDescriptor?, to entry: PanelEntry) {
        switch entry.source {
        case let .builtin(item):
            panel.setBuiltinHotkey(item, hotkey: hotkey)
        case let .appShortcut(id):
            panel.updateAppShortcut(id: id, hotkey: hotkey)
        case .installedApp, .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion, .paletteOption, .hostProfile:
            // Command-palette-only source; never surfaces in the settings UI.
            break
        }
    }

    private func clearHotkey(for source: PanelEntry.Source) {
        switch source {
        case let .builtin(item):
            panel.setBuiltinHotkey(item, hotkey: nil)
        case let .appShortcut(id):
            panel.updateAppShortcut(id: id, hotkey: nil)
        case .installedApp, .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion, .paletteOption, .hostProfile:
            // Command-palette-only source; never surfaces in the settings UI.
            break
        }
    }

    // MARK: Drag-to-reorder

    /// The grab handle plus its reorder gesture. Rows in a `.fixed` group never
    /// reach here (their builders draw no handle), so every handle is draggable.
    private func dragHandle(for row: PanelSettingsRow) -> some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(drag?.rowID == row.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            // Grow the grab/hover target from the bare glyph to the full column
            // width and row height.
            .frame(width: Self.handleColumnWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .hoverCursor(.openHand)
            .gesture(dragGesture(for: row))
    }

    /// Measures a row's frame into the shared `listSpace` so the drag can map the
    /// pointer to an insertion index.
    private func rowFrameReader(_ row: PanelSettingsRow) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: RowFrameKey.self,
                value: [row.id: geo.frame(in: .named(Self.listSpace))]
            )
        }
    }

    /// A custom drag confined to the dragged row's group: the pointer's Y maps to
    /// an insertion index among the same-group peers, an accent line previews the
    /// drop, and release commits through the matching reorder method.
    private func dragGesture(for row: PanelSettingsRow) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
            .onChanged { value in
                if drag?.rowID != row.id {
                    withAnimation(.snappy(duration: 0.16)) {
                        drag = DragSession(rowID: row.id, group: row.group,
                                           dropIndex: groupIndex(of: row))
                    }
                }
                let midYs = peers(of: row.group, excluding: row.id)
                    .compactMap { rowFrames[$0.id]?.midY }
                let index = PanelDrag.dropIndex(pointerY: value.location.y, peerMidYs: midYs)
                if drag?.dropIndex != index {
                    withAnimation(.snappy(duration: 0.16)) { drag?.dropIndex = index }
                }
            }
            .onEnded { _ in
                guard let session = drag, session.rowID == row.id else { return }
                commitDrag(session)
                withAnimation(.snappy(duration: 0.18)) { drag = nil }
            }
    }

    /// Same-group rows in display order (optionally excluding one id). A drag only
    /// ever reorders within this set.
    private func peers(of group: PanelDragGroup, excluding excludedID: String? = nil) -> [PanelSettingsRow] {
        displayRows.filter { $0.group == group && $0.id != excludedID }
    }

    /// The dragged row's current position among its peers — the drop index that
    /// would leave the order unchanged.
    private func groupIndex(of row: PanelSettingsRow) -> Int {
        peers(of: row.group).firstIndex { $0.id == row.id } ?? 0
    }

    /// Routes a finished drag to the reorder method for its group, rebuilding the
    /// group's order with the dragged element reinserted at the drop index.
    private func commitDrag(_ session: DragSession) {
        let groupRows = peers(of: session.group)
        switch session.group {
        case .topLevel:
            let items = groupRows.compactMap(builtinItem(of:))
            guard let dragged = builtinItem(ofRowID: session.rowID) else { return }
            panel.reorderTopLevel(by: PanelDrag.reordered(items, moving: dragged, to: session.dropIndex))
        case .appChild:
            let ids = groupRows.compactMap(appShortcutID(of:))
            guard let dragged = appShortcutID(ofRowID: session.rowID) else { return }
            panel.reorderAppShortcuts(by: PanelDrag.reordered(ids, moving: dragged, to: session.dropIndex))
        case .windowChild:
            let items = groupRows.compactMap(builtinItem(of:))
            guard let dragged = builtinItem(ofRowID: session.rowID) else { return }
            panel.reorderWindowChildren(by: PanelDrag.reordered(items, moving: dragged, to: session.dropIndex))
        case .fixed:
            break
        }
    }

    /// The accent insertion line, positioned between the dragged row's peers.
    @ViewBuilder
    private var insertionIndicator: some View {
        if let drag, let y = insertionLineY(drag) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
                .offset(y: y - 1)
                .allowsHitTesting(false)
        }
    }

    /// Y (in `listSpace`) of the drop line for the current drag: the top of the
    /// target peer, the midpoint between two peers, or the bottom of the last.
    private func insertionLineY(_ session: DragSession) -> CGFloat? {
        let rects = peers(of: session.group, excluding: session.rowID)
            .compactMap { rowFrames[$0.id] }
            .sorted { $0.minY < $1.minY }
        guard let lastRect = rects.last else { return nil }
        let index = min(max(session.dropIndex, 0), rects.count)
        // Anchor the line to the TOP of the peer that will follow the dropped
        // row, not the midpoint of the gap above it. When a top-level parent is
        // expanded its child rows sit in that gap, so the old midpoint floated
        // the line into the middle of the children instead of at the boundary.
        if index < rects.count {
            return rects[index].minY
        }
        // Dropping past the last peer. A top-level peer may be an expanded parent
        // whose children sit below it; since it is the last top-level row,
        // everything rendered below it belongs to its block, so extend to the
        // bottom of the last child. Child groups have no sub-rows — the peer's
        // own bottom is the boundary.
        if session.group == .topLevel {
            let blockBottom = rowFrames
                .filter { $0.key != session.rowID && $0.value.minY >= lastRect.minY }
                .values.map(\.maxY).max()
            return blockBottom ?? lastRect.maxY
        }
        return lastRect.maxY
    }

    // MARK: Row identity helpers

    private func builtinItem(of row: PanelSettingsRow) -> BuiltinItem? {
        if case let .entry(entry) = row.content, case let .builtin(item) = entry.source { return item }
        return nil
    }
    private func appShortcutID(of row: PanelSettingsRow) -> UUID? {
        if case let .entry(entry) = row.content, case let .appShortcut(id) = entry.source { return id }
        return nil
    }
    private func builtinItem(ofRowID id: String) -> BuiltinItem? {
        displayRows.first { $0.id == id }.flatMap(builtinItem(of:))
    }
    private func appShortcutID(ofRowID id: String) -> UUID? {
        displayRows.first { $0.id == id }.flatMap(appShortcutID(of:))
    }

    private func appChildRow(_ child: PanelEntry, row: PanelSettingsRow) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2).padding(.leading, 16)
            if isEditing {
                dragHandle(for: row)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                // App-shortcut children have no visibility checkbox, but reserve
                // the checkbox-column width so the icon stays aligned with the
                // parent row's checkbox in edit mode.
                Color.clear.frame(width: PanelCheckbox.width)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            AppShortcutIcon(path: appShortcutPath(for: child), fallbackSymbol: child.symbol)
            Text(child.localizedTitle()).font(.body)
            Spacer()
            HotkeyRecorder(
                hotkey: .constant(child.hotkey),
                onChange: { newValue in handleHotkeyChange(entry: child, newValue: newValue) },
                allowsClear: false
            )
            .frame(width: 150, alignment: .trailing)
            deleteButton(for: child)
        }
        .padding(.vertical, 3)
    }

    /// The on-disk app path for an app-shortcut row, read from the prebuilt path
    /// map (no per-render SwiftData fetch).
    private func appShortcutPath(for entry: PanelEntry) -> String? {
        if case let .appShortcut(id) = entry.source { return panel.appShortcutPaths[id] }
        return nil
    }

    private func windowChildRow(_ child: PanelEntry, row: PanelSettingsRow) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2).padding(.leading, 16)
            if isEditing {
                dragHandle(for: row)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                // Reserve the checkbox-column width so the icon stays aligned with
                // the parent row's checkbox in edit mode.
                Color.clear.frame(width: PanelCheckbox.width)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Image(systemName: child.symbol).frame(width: 18)
            Text(child.localizedTitle()).font(.body)
            Spacer()
            HotkeyRecorder(hotkey: .constant(child.hotkey)) { newValue in
                handleHotkeyChange(entry: child, newValue: newValue)
            }
            .frame(width: 150, alignment: .trailing)
            Color.clear.frame(width: 20)
        }
        .padding(.vertical, 3)
    }

    private func addAppButton() -> some View {
        HStack {
            Spacer().frame(width: 38)
            Button {
                addApp()
            } label: {
                Label { LocalizedText(.settingsPanelAddApp) } icon: { Image(systemName: "plus") }
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .hoverCursor(.pointingHand)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func addApp() {
        let apps = InstalledAppsScanner.scan()
        let excluded = Set(panel.appShortcutChildren.compactMap { entry -> String? in
            if case let .appShortcut(id) = entry.source,
               let binding = PanelStore.shared.binding(id: id) {
                return binding.appBundleID
            }
            return nil
        })
        SpotlightAppPickerWindowController.shared.show(apps: apps, excluded: excluded) { app in
            PanelStore.shared.addAppShortcut(
                appBundleID: app.bundleID,
                appName: app.displayName,
                appPath: app.path
            )
        }
    }

}

/// Lightweight pure-SwiftUI checkbox for the visibility column. Replaces
/// `Toggle(.checkbox)` + `noFocusRing()`: the native checkbox is an NSButton and
/// the focus-ring suppressor an NSView probe, and ~33 of each (one per top-level
/// row) dominated the Panel tab's switch cost (~85ms of ~140ms — see profiling).
/// A `Button` + SF Symbol renders the same affordance with no AppKit backing and
/// no focus ring to suppress.
private struct PanelCheckbox: View {
    @Binding var isOn: Bool

    /// Shared checkbox-column width so child rows can reserve an aligned spacer.
    static let width: CGFloat = 16

    /// Side length of the drawn box; matches the native checkbox (~14pt).
    private static let box: CGFloat = 14

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            glyph
                .frame(width: Self.width, height: Self.width)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverCursor(.pointingHand)
    }

    // Hand-drawn to track the native checkbox: a rounded square that fills with
    // the accent color and shows a bold white checkmark when on, and is an empty
    // control-background square with a thin hairline border when off.
    private var glyph: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: .textBackgroundColor)))
            .overlay {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(isOn ? Color.accentColor : Color.secondary.opacity(0.45),
                                  lineWidth: 1)
            }
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: Self.box, height: Self.box)
    }
}

/// The Finder icon for an app-shortcut row. Loads the icon through the shared
/// `AppIconCache` in a `.task` (warm path resolves synchronously from cache;
/// cold path reads disk OFF the main thread inside the cache), so scrolling a
/// fresh app row into view never blocks the main thread. Resolving the icon
/// inline in the row body — the old `NSWorkspace.icon(forFile:)` call — dropped
/// scroll frames as the List recycled rows.
private struct AppShortcutIcon: View {
    let path: String?
    let fallbackSymbol: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: fallbackSymbol).frame(width: 18)
            }
        }
        .task(id: path) {
            guard let path else { image = nil; return }
            if let cached = AppIconCache.cached(path) {
                image = cached
            } else {
                image = await AppIconCache.icon(for: path)
            }
        }
    }
}

/// An in-flight Panel settings reorder drag.
private struct DragSession {
    let rowID: String
    let group: PanelDragGroup
    var dropIndex: Int
}

/// Collects each row's frame in the list coordinate space for the drag.
private struct RowFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ConflictAlert: Identifiable {
    let id = UUID()
    let hotkey: HotkeyDescriptor
    let existingTitle: String
    let onReplace: () -> Void
}

private struct PendingDelete: Identifiable {
    let id = UUID()
    let bindingID: UUID
    let appName: String
}
