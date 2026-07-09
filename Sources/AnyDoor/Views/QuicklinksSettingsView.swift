import SwiftUI

@MainActor
struct QuicklinksSettingsView: View {
    @State private var store = QuicklinkStore.shared
    @State private var editorDraft: QuicklinkEditorDraft?
    @State private var pendingDelete: QuicklinkPendingDelete?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var drag: QuicklinkDragSession?

    private static let listSpace = "quicklinksSettingsList"

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 0) {
                    if store.quicklinks.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.quicklinks) { quicklink in
                            row(for: quicklink)
                                .background(rowFrameReader(quicklink))
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.accentColor.opacity(drag?.quicklinkID == quicklink.id ? 0.10 : 0))
                                )
                                .scaleEffect(drag?.quicklinkID == quicklink.id ? 1.01 : 1)
                                .shadow(color: .black.opacity(drag?.quicklinkID == quicklink.id ? 0.16 : 0),
                                        radius: drag?.quicklinkID == quicklink.id ? 5 : 0, y: 2)
                                .zIndex(drag?.quicklinkID == quicklink.id ? 1 : 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .coordinateSpace(name: Self.listSpace)
                .overlay(alignment: .topLeading) { insertionIndicator }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 12)
                .onPreferenceChange(QuicklinkRowFrameKey.self) { frames in
                    MainThreadIsolation.run { rowFrames = frames }
                }
            }
            .overlayScrollers()
            .scrollClipDisabled()
        }
        .sheet(item: $editorDraft) { draft in
            QuicklinkEditorSheet(draft: draft) { saved in
                try save(saved)
            }
        }
        .alert(item: $pendingDelete) { item in
            Alert(
                title: Text(L(.settingsQuicklinksDeleteTitle, item.title)),
                message: Text(L(.settingsQuicklinksDeleteMessage)),
                primaryButton: .destructive(Text(L(.settingsQuicklinksDelete))) {
                    store.delete(id: item.quicklinkID)
                },
                secondaryButton: .cancel(Text(L(.settingsQuicklinksCancel)))
            )
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button {
                editorDraft = QuicklinkEditorDraft()
            } label: {
                Label { LocalizedText(.settingsQuicklinksAdd) } icon: { Image(systemName: "plus") }
                    .font(.body)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .hoverCursor(.pointingHand)
        }
        .padding(.horizontal, 14)
        .offset(y: -21)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "link")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.tertiary)
            LocalizedText(.settingsQuicklinksEmpty)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Button {
                editorDraft = QuicklinkEditorDraft()
            } label: {
                Label { LocalizedText(.settingsQuicklinksAdd) } icon: { Image(systemName: "plus") }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func row(for quicklink: Quicklink) -> some View {
        HStack(spacing: 10) {
            dragHandle(for: quicklink)
            QuicklinkIconView(
                request: QuicklinkIconRequest(
                    link: quicklink.link,
                    openWithBundleID: quicklink.openWithBundleID
                ),
                fallbackSymbol: "link",
                size: 20,
                symbolPointSize: 14
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(quicklink.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(quicklink.link)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let keyword = quicklink.keyword?.trimmingCharacters(in: .whitespacesAndNewlines),
               !keyword.isEmpty {
                Text(keyword)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
            }
            if !quicklink.isVisible {
                Label {
                    LocalizedText(.settingsQuicklinksHiddenBadge)
                } icon: {
                    Image(systemName: "eye.slash")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Button {
                editorDraft = QuicklinkEditorDraft(quicklink: quicklink)
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L(.settingsQuicklinksEdit))
            .hoverCursor(.pointingHand)

            Button {
                pendingDelete = QuicklinkPendingDelete(quicklink: quicklink)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L(.settingsQuicklinksDelete))
            .hoverCursor(.pointingHand)
        }
        .opacity(quicklink.isVisible ? 1.0 : 0.55)
        .padding(.vertical, 7)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                editorDraft = QuicklinkEditorDraft(quicklink: quicklink)
            } label: {
                Label(L(.settingsQuicklinksEdit), systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingDelete = QuicklinkPendingDelete(quicklink: quicklink)
            } label: {
                Label(L(.settingsQuicklinksDelete), systemImage: "trash")
            }
        }
    }

    private func dragHandle(for quicklink: Quicklink) -> some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(drag?.quicklinkID == quicklink.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .frame(width: 24)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .hoverCursor(.openHand)
            .gesture(dragGesture(for: quicklink))
    }

    private func rowFrameReader(_ quicklink: Quicklink) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: QuicklinkRowFrameKey.self,
                value: [quicklink.id: geo.frame(in: .named(Self.listSpace))]
            )
        }
    }

    private func dragGesture(for quicklink: Quicklink) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.listSpace))
            .onChanged { (gestureValue: DragGesture.Value) in
                if drag?.quicklinkID != quicklink.id {
                    withAnimation(.snappy(duration: 0.16)) {
                        drag = QuicklinkDragSession(
                            quicklinkID: quicklink.id,
                            dropIndex: currentIndex(of: quicklink.id)
                        )
                    }
                }
                let pointerY = gestureValue.location.y
                let midYs = peerMidYs(excluding: quicklink.id)
                let index = PanelDrag.dropIndex(pointerY: pointerY, peerMidYs: midYs)
                if drag?.dropIndex != index {
                    withAnimation(.snappy(duration: 0.16)) { drag?.dropIndex = index }
                }
            }
            .onEnded { _ in
                guard let session = drag, session.quicklinkID == quicklink.id else { return }
                let ids = orderedIDs()
                store.reorder(by: PanelDrag.reordered(ids, moving: session.quicklinkID, to: session.dropIndex))
                withAnimation(.snappy(duration: 0.18)) { drag = nil }
            }
    }

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

    private func insertionLineY(_ session: QuicklinkDragSession) -> CGFloat? {
        let rects = peerRects(excluding: session.quicklinkID)
        guard let lastRect = rects.last else { return nil }
        let index = min(max(session.dropIndex, 0), rects.count)
        if index < rects.count { return rects[index].minY }
        return lastRect.maxY
    }

    private func currentIndex(of id: UUID) -> Int {
        orderedIDs().firstIndex(of: id) ?? 0
    }

    private func orderedIDs() -> [UUID] {
        store.quicklinks.map { $0.id }
    }

    private func peerMidYs(excluding id: UUID) -> [CGFloat] {
        let frames = rowFrames
        return orderedIDs()
            .filter { $0 != id }
            .compactMap { frames[$0]?.midY }
    }

    private func peerRects(excluding id: UUID) -> [CGRect] {
        let frames = rowFrames
        return orderedIDs()
            .filter { $0 != id }
            .compactMap { frames[$0] }
            .sorted { $0.minY < $1.minY }
    }

    private func save(_ draft: QuicklinkEditorDraft) throws {
        if let id = draft.quicklinkID {
            try store.update(
                id: id,
                name: draft.name,
                link: draft.link,
                keyword: draft.keyword,
                openWithBundleID: draft.openWithBundleID,
                hotkey: draft.hotkey,
                isVisible: draft.isVisible
            )
        } else {
            try store.add(
                name: draft.name,
                link: draft.link,
                keyword: draft.keyword,
                openWithBundleID: draft.openWithBundleID,
                hotkey: draft.hotkey,
                isVisible: draft.isVisible
            )
        }
    }
}

private struct QuicklinkEditorDraft: Identifiable {
    let id = UUID()
    let quicklinkID: UUID?
    var name: String
    var link: String
    var keyword: String
    var openWithBundleID: String?
    var hotkey: HotkeyDescriptor?
    var isVisible: Bool

    init() {
        self.quicklinkID = nil
        self.name = ""
        self.link = ""
        self.keyword = ""
        self.openWithBundleID = nil
        self.hotkey = nil
        self.isVisible = true
    }

    init(quicklink: Quicklink) {
        self.quicklinkID = quicklink.id
        self.name = quicklink.name
        self.link = quicklink.link
        self.keyword = quicklink.keyword ?? ""
        self.openWithBundleID = quicklink.openWithBundleID
        self.hotkey = quicklink.hotkeyDescriptor
        self.isVisible = quicklink.isVisible
    }
}

private struct QuicklinkEditorSheet: View {
    let draft: QuicklinkEditorDraft
    let onSave: (QuicklinkEditorDraft) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var link: String
    @State private var keyword: String
    @State private var openWithBundleID: String
    @State private var hotkey: HotkeyDescriptor?
    @State private var isVisible: Bool
    @State private var installedApps: [InstalledApp] = []
    @State private var errorMessage: String?

    init(draft: QuicklinkEditorDraft, onSave: @escaping (QuicklinkEditorDraft) throws -> Void) {
        self.draft = draft
        self.onSave = onSave
        _name = State(initialValue: draft.name)
        _link = State(initialValue: draft.link)
        _keyword = State(initialValue: draft.keyword)
        _openWithBundleID = State(initialValue: draft.openWithBundleID ?? "")
        _hotkey = State(initialValue: draft.hotkey)
        _isVisible = State(initialValue: draft.isVisible)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(draft.quicklinkID == nil ? L(.settingsQuicklinksNewTitle) : L(.settingsQuicklinksEditTitle))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 4)

            Form {
                Section {
                    TextField(text: $name, prompt: Text(L(.settingsQuicklinksNamePrompt))) {
                        LocalizedText(.settingsQuicklinksName)
                    }
                    TextField(text: $link, prompt: Text(L(.settingsQuicklinksLinkPrompt))) {
                        LocalizedText(.settingsQuicklinksLink)
                    }
                } header: {
                    LocalizedText(.settingsQuicklinksBasicsSection)
                } footer: {
                    LocalizedText(.settingsQuicklinksLinkFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField(text: $keyword, prompt: Text(L(.settingsQuicklinksKeywordPrompt))) {
                        LocalizedText(.settingsQuicklinksKeyword)
                    }
                    Picker(selection: $openWithBundleID) {
                        Text(L(.settingsQuicklinksOpenWithDefault)).tag("")
                        if selectedOpenWithIsMissing {
                            Text(openWithBundleID).tag(openWithBundleID)
                        }
                        ForEach(installedApps) { app in
                            Text(app.displayName).tag(app.bundleID)
                        }
                    } label: {
                        LocalizedText(.settingsQuicklinksOpenWith)
                    }
                    LabeledContent {
                        HotkeyRecorder(hotkey: $hotkey) { _ in }
                            .frame(maxWidth: 180, alignment: .trailing)
                    } label: {
                        LocalizedText(.settingsQuicklinksHotkey)
                    }
                    Toggle(isOn: hidden) {
                        LocalizedText(.settingsQuicklinksHidden)
                    }
                } header: {
                    LocalizedText(.settingsQuicklinksPaletteSection)
                } footer: {
                    LocalizedText(.settingsQuicklinksPaletteFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            VStack(spacing: 10) {
                if let errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(errorMessage)
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                HStack(spacing: 10) {
                    Spacer()
                    Button(L(.settingsQuicklinksCancel)) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(L(.settingsQuicklinksSave)) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480, height: 600)
        .task { await loadInstalledApps() }
    }

    private var hidden: Binding<Bool> {
        Binding(
            get: { !isVisible },
            set: { isVisible = !$0 }
        )
    }

    private var selectedOpenWithIsMissing: Bool {
        !openWithBundleID.isEmpty && !installedApps.contains { $0.bundleID == openWithBundleID }
    }

    private func loadInstalledApps() async {
        let apps = await Task.detached(priority: .userInitiated) {
            InstalledAppsScanner.scan()
        }.value
        installedApps = apps
    }

    private func save() {
        do {
            try onSave(QuicklinkEditorDraft(
                quicklinkID: draft.quicklinkID,
                name: name,
                link: link,
                keyword: keyword,
                openWithBundleID: openWithBundleID,
                hotkey: hotkey,
                isVisible: isVisible
            ))
            dismiss()
        } catch QuicklinkStoreError.linkRequired {
            errorMessage = L(.settingsQuicklinksLinkRequired)
        } catch QuicklinkStoreError.keywordAlreadyUsed {
            errorMessage = L(.settingsQuicklinksKeywordDuplicate)
        } catch {
            errorMessage = L(.settingsQuicklinksSaveFailed)
        }
    }
}

private extension QuicklinkEditorDraft {
    init(
        quicklinkID: UUID?,
        name: String,
        link: String,
        keyword: String,
        openWithBundleID: String?,
        hotkey: HotkeyDescriptor?,
        isVisible: Bool
    ) {
        self.quicklinkID = quicklinkID
        self.name = name
        self.link = link
        self.keyword = keyword
        self.openWithBundleID = QuicklinkOpenWith.normalizedBundleID(openWithBundleID)
        self.hotkey = hotkey
        self.isVisible = isVisible
    }
}

private struct QuicklinkPendingDelete: Identifiable {
    let id = UUID()
    let quicklinkID: UUID
    let title: String

    init(quicklink: Quicklink) {
        self.quicklinkID = quicklink.id
        self.title = quicklink.displayName
    }
}

private struct QuicklinkDragSession {
    let quicklinkID: UUID
    var dropIndex: Int
}

private struct QuicklinkRowFrameKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
