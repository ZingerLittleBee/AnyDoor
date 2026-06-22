import SwiftUI

/// Source ⇄ target language selector. The source picker's first entry is
/// "Auto Detect" (binds to a nil source); when auto is active and a language has
/// been detected, the menu label shows the detected language as a hint. The swap
/// button delegates to the coordinator so an auto source resolves to the
/// detected language before swapping.
///
/// Each side is a soft-filled capsule with a single trailing chevron (the system
/// menu indicator is hidden) and a hover highlight; the swap control is a round
/// icon button between them. The two pickers occupy equal flexible halves and are
/// centered within their own half, so both sides have the same footprint and the
/// swap icon stays geometrically centered no matter how long the language names
/// are. Swap is also bound to ⌘S.
struct LanguageBar: View {
    @Bindable var coordinator: TranslationCoordinator
    /// Called after any language change (source/target/swap) so the host can
    /// re-run translation if there is input text.
    var onChange: () -> Void = {}

    @State private var sourceHovered = false
    @State private var targetHovered = false
    @State private var swapHovered = false

    var body: some View {
        HStack(spacing: 8) {
            sourcePicker
                .frame(maxWidth: .infinity, alignment: .center)
            swapButton
            targetPicker
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .font(.callout)
    }

    private var sourcePicker: some View {
        Menu {
            Button {
                coordinator.source = nil
                onChange()
            } label: {
                row(title: L(.translationAutoDetect), selected: coordinator.source == nil)
            }
            Divider()
            ForEach(TranslationLanguage.catalog) { lang in
                Button {
                    coordinator.source = lang
                    onChange()
                } label: {
                    row(title: lang.displayName(), selected: coordinator.source == lang)
                }
            }
        } label: {
            capsule(sourceLabel, hovered: sourceHovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { sourceHovered = $0 }
    }

    private var targetPicker: some View {
        Menu {
            ForEach(TranslationLanguage.catalog) { lang in
                Button {
                    coordinator.target = lang
                    onChange()
                } label: {
                    row(title: lang.displayName(), selected: coordinator.target == lang)
                }
            }
        } label: {
            capsule(coordinator.target.displayName(), hovered: targetHovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { targetHovered = $0 }
    }

    private var swapButton: some View {
        Button {
            coordinator.swapLanguages()
            onChange()
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(fill(swapHovered)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { swapHovered = $0 }
        // ⌘S swaps source/target; the panel is key while open, so the hosting
        // view's performKeyEquivalent fires this even while the input has focus.
        .keyboardShortcut("s", modifiers: .command)
        // Surface the shortcut in the tooltip (a plain button's help text isn't
        // auto-decorated with its key equivalent the way a menu item's is).
        .help(L(.translationSwapLanguages) + " ⌘S")
    }

    /// The capsule label shared by both pickers: title + a single trailing
    /// chevron, on a soft fill that brightens on hover.
    private func capsule(_ title: String, hovered: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(fill(hovered)))
        .contentShape(Capsule())
    }

    private func fill(_ hovered: Bool) -> Color {
        Color.primary.opacity(hovered ? 0.12 : 0.06)
    }

    /// Source button title: the chosen language, or "Auto Detect" plus the
    /// detected language hint when running in auto-detect mode.
    private var sourceLabel: String {
        if let source = coordinator.source {
            return source.displayName()
        }
        if let detected = coordinator.detectedSource {
            return L(.translationAutoDetectHint, detected.displayName())
        }
        return L(.translationAutoDetect)
    }

    @ViewBuilder
    private func row(title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
