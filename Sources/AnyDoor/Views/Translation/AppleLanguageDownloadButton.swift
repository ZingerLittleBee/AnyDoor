import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Trailing control in the Apple service settings row that proactively downloads
/// the on-device translation assets for the two configured target languages, so
/// the first real translation doesn't have to stop and fetch a language pack.
///
/// The displayed state always reflects the *real* status reported by
/// `LanguageAvailability` — never just whether `prepareTranslation()` returned,
/// because that call also returns normally when the person dismisses the system
/// download sheet without downloading. On macOS 14 (no Translation API) it renders
/// nothing, mirroring `AppleTranslationCard`.
struct AppleLanguageDownloadButton: View {
    let target: TranslationLanguage
    let secondTarget: TranslationLanguage

    var body: some View {
        if #available(macOS 15, *) {
            AppleLanguageDownloadButtonBody(target: target, secondTarget: secondTarget)
        } else {
            EmptyView()
        }
    }
}

#if canImport(Translation)
/// Drives one proactive download and tracks the real installed status via the
/// shared `AppleLanguagePackModel`. Apple's translation assets are per-language
/// and shared system-wide, so downloading a single direction
/// (`secondTarget → target`) installs both languages and makes the reverse
/// direction available too.
@available(macOS 15, *)
private struct AppleLanguageDownloadButtonBody: View {
    let target: TranslationLanguage
    let secondTarget: TranslationLanguage

    @State private var model = AppleLanguagePackModel()

    /// One representative direction is enough (assets are per-language). Nil when
    /// both configured languages are the same.
    private var pair: AppleLanguagePackModel.LanguagePair? {
        guard target.code != secondTarget.code else { return nil }
        return .init(source: secondTarget.code, target: target.code)
    }

    var body: some View {
        control
            .font(.callout)
            .help(L(.settingsTranslationDownloadLanguagesHelp, target.displayName(), secondTarget.displayName()))
            // Re-evaluate real status on appear and whenever either configured
            // language changes, so the control never shows a stale result.
            .task(id: "\(target.code)|\(secondTarget.code)") {
                await model.evaluate(pair: pair)
            }
            .translationTask(model.configuration) { @Sendable [model] session in
                // @Sendable keeps the closure nonisolated so `session` can reach
                // Apple's nonisolated prepareTranslation(); state writes hop back
                // to the MainActor via `await`.
                await runApplePrepare(session, model: model)
            }
    }

    @ViewBuilder
    private var control: some View {
        switch model.phase {
        case .checking:
            ProgressView().controlSize(.small)
        case .needsDownload:
            Button { model.startDownload() } label: {
                LocalizedText(.settingsTranslationDownloadLanguages)
            }
            .buttonStyle(.borderless)
        case .downloading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                LocalizedText(.settingsTranslationDownloadLanguagesDownloading)
                    .foregroundStyle(.secondary)
            }
        case .installed:
            Label {
                LocalizedText(.settingsTranslationDownloadLanguagesDone)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)
        case .unsupported:
            Label {
                LocalizedText(.settingsTranslationDownloadLanguagesUnsupported)
            } icon: {
                Image(systemName: "slash.circle")
            }
            .foregroundStyle(.secondary)
        case .failed:
            Button { model.startDownload() } label: {
                Label {
                    LocalizedText(.settingsTranslationDownloadLanguagesFailed)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.orange)
        }
    }
}
#endif
