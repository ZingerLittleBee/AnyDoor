import SwiftUI

/// Source ⇄ target language selector. The source picker's first entry is
/// "Auto Detect" (binds to a nil source); when auto is active and a language has
/// been detected, the menu label shows the detected language as a hint. The swap
/// button delegates to the coordinator so an auto source resolves to the
/// detected language before swapping.
struct LanguageBar: View {
    @Bindable var coordinator: TranslationCoordinator
    /// Called after any language change (source/target/swap) so the host can
    /// re-run translation if there is input text.
    var onChange: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            sourcePicker
            Button {
                coordinator.swapLanguages()
                onChange()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .help(L(.translationSwapLanguages))

            targetPicker
        }
        .font(.callout)
    }

    private var sourcePicker: some View {
        Menu {
            Button {
                coordinator.source = nil
                onChange()
            } label: {
                sourceRow(title: L(.translationAutoDetect), selected: coordinator.source == nil)
            }
            Divider()
            ForEach(TranslationLanguage.catalog) { lang in
                Button {
                    coordinator.source = lang
                    onChange()
                } label: {
                    sourceRow(title: lang.displayName(), selected: coordinator.source == lang)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(sourceLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var targetPicker: some View {
        Menu {
            ForEach(TranslationLanguage.catalog) { lang in
                Button {
                    coordinator.target = lang
                    onChange()
                } label: {
                    sourceRow(title: lang.displayName(), selected: coordinator.target == lang)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(coordinator.target.displayName()).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Source button title: the chosen language, or "Auto" plus the detected
    /// language hint in parentheses when running in auto-detect mode.
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
    private func sourceRow(title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}
