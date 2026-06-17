import SwiftUI

/// Step 6 — "Tune it to your workflow". A simplified Panel Settings list that
/// demos drag-reordering and live hotkey recording, plus the real entry point
/// into Settings. No setting is actually written here.
struct OnboardingCustomizeStep: View {
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct RowModel: Identifiable, Equatable {
        let id = UUID()
        let symbol: String
        let titleKey: L10n.Key
        let badgeKey: L10n.Key
        let accessory: OnboardingRowAccessory
        let recordable: Bool
    }

    @State private var rows: [RowModel] = [
        RowModel(symbol: "cup.and.saucer.fill", titleKey: .builtinKeepAwake, badgeKey: .settingsPanelTypeBadgeToggle, accessory: .toggle(true), recordable: false),
        RowModel(symbol: "doc.on.clipboard", titleKey: .builtinClipboardWall, badgeKey: .settingsPanelTypeBadgeAction, accessory: .hotkey("⌘⇧V"), recordable: false),
        RowModel(symbol: "camera.viewfinder", titleKey: .builtinScreenshot, badgeKey: .settingsPanelTypeBadgeAction, accessory: .hotkey(""), recordable: true),
        RowModel(symbol: "macwindow", titleKey: .builtinWindowLayout, badgeKey: .settingsPanelTypeBadgeSubmenu, accessory: .chevron, recordable: false),
    ]
    @State private var liftedID: UUID?
    @State private var recording = false

    var body: some View {
        OnboardingDemoStage(tint: .pink) {
            VStack(alignment: .leading, spacing: 10) {
                list

                HStack(spacing: 14) {
                    Label { LocalizedText(.onboardingCustomizeDragHint) } icon: { Image(systemName: "arrow.up.arrow.down") }
                    Label { LocalizedText(.onboardingCustomizeRecordHint) } icon: { Image(systemName: "record.circle") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                HStack {
                    Label { LocalizedText(.onboardingCustomizeMenuBarHint) } icon: { Image(systemName: "arrow.up.forward") }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        SettingsOpener.shared.tryOpen()
                        onClose()
                    } label: {
                        Label { LocalizedText(.onboardingCustomizeOpenSettings) } icon: { Image(systemName: "gearshape") }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(14)
        }
        .task { await runReorderLoop() }
        .task { await runRecordLoop() }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 1) {
            ForEach(rows) { row in
                settingsRow(row)
                    .scaleEffect(liftedID == row.id ? 1.03 : 1.0)
                    .shadow(color: .black.opacity(liftedID == row.id ? 0.18 : 0), radius: liftedID == row.id ? 6 : 0, y: 2)
                    .zIndex(liftedID == row.id ? 1 : 0)
            }

            Divider().padding(.vertical, 3)

            brightnessHiddenHotkeys

            addAppButton
        }
        .padding(8)
        .background(.background, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.quaternary, lineWidth: 1)
        }
        .onboardingAnimation(.spring(response: 0.4, dampingFraction: 0.78), reduceMotion: reduceMotion, value: rows)
    }

    private func settingsRow(_ row: RowModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.tertiary)
            Image(systemName: "checkmark.square.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor)
            Image(systemName: row.symbol).font(.system(size: 12)).frame(width: 18).foregroundStyle(.primary)
            LocalizedText(row.titleKey).font(.system(size: 12))
            LocalizedText(row.badgeKey).font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            accessory(for: row)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(liftedID == row.id ? Color.accentColor.opacity(0.08) : .clear)
        }
    }

    @ViewBuilder
    private func accessory(for row: RowModel) -> some View {
        if row.recordable {
            recorderField
        } else {
            switch row.accessory {
            case let .hotkey(text):
                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            case .chevron:
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            case let .toggle(isOn):
                Capsule().fill(isOn ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 28, height: 16)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 12, height: 12).padding(2)
                    }
            case .none:
                EmptyView()
            }
        }
    }

    private var recorderField: some View {
        Group {
            if recording {
                LocalizedText(.onboardingCustomizeRecordingState)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("⌃⌥⌘ S")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, height: 20)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(recording ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor : .clear, lineWidth: 1)
                }
        }
        .onboardingAnimation(.easeInOut(duration: 0.25), reduceMotion: reduceMotion, value: recording)
    }

    private var brightnessHiddenHotkeys: some View {
        VStack(spacing: 2) {
            hiddenHotkeyRow(symbol: "sun.max", titleKey: .builtinBrightnessUp, combo: "⌃⌥ ↑")
            hiddenHotkeyRow(symbol: "sun.min", titleKey: .builtinBrightnessDown, combo: "⌃⌥ ↓")
        }
        .padding(.leading, 26)
    }

    private func hiddenHotkeyRow(symbol: String, titleKey: L10n.Key, combo: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10)).frame(width: 16).foregroundStyle(.secondary)
            LocalizedText(titleKey).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(combo)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private var addAppButton: some View {
        HStack {
            Spacer().frame(width: 28)
            HStack(spacing: 4) {
                Image(systemName: "plus")
                LocalizedText(.settingsPanelAddApp)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Spacer()
        }
        .padding(.top, 3)
    }

    // MARK: Demo timelines

    private func runReorderLoop() async {
        if reduceMotion { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2200))
            if Task.isCancelled { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { liftedID = rows.first?.id }
            try? await Task.sleep(for: .milliseconds(220))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                if rows.count > 1 { rows.swapAt(0, 1) }
            }
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.easeOut(duration: 0.2)) { liftedID = nil }
        }
    }

    private func runRecordLoop() async {
        if reduceMotion { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(3200))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.2)) { recording = true }
            try? await Task.sleep(for: .milliseconds(1100))
            withAnimation(.easeInOut(duration: 0.2)) { recording = false }
        }
    }
}
