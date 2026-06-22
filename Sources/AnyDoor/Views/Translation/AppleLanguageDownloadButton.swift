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
/// Drives one proactive download and tracks the real installed status. Apple's
/// translation assets are per-language and shared system-wide, so downloading a
/// single direction (`secondTarget → target`) installs both languages and makes
/// the reverse direction available too — no need to prepare both ways. A
/// `generation` token supersedes stale async work when the configured languages
/// change mid-flight. `@MainActor @Observable` so the control binds to `phase` and
/// the `nonisolated` task closure can publish back via `await`.
@available(macOS 15, *)
@MainActor
@Observable
private final class AppleDownloadModel {
    enum Phase: Equatable { case checking, idle, downloading, done, unsupported, failed }

    var phase: Phase = .checking
    var configuration: TranslationSession.Configuration?
    /// Exposed so the `nonisolated` runner can stamp the run it belongs to and
    /// re-guard against being superseded.
    var currentGeneration: Int { generation }

    /// The representative direction to install (nil when both languages match —
    /// the framework can't translate a language to itself).
    private var pair: LanguagePair?
    private var generation = 0

    struct LanguagePair: Equatable {
        let source: String
        let target: String
    }

    /// Re-read the real status for `pair` (on appear / language change). Skipped
    /// while a download is active so a `.task` re-run (e.g. returning to the tab)
    /// can't clobber it.
    func evaluate(pair: LanguagePair?) async {
        guard phase != .downloading else { return }
        self.pair = pair
        generation += 1
        let gen = generation
        configuration = nil
        guard let pair else { phase = .done; return }
        phase = .checking
        let status = await statusOf(pair)
        guard gen == generation else { return }
        phase = Self.phase(for: status)
    }

    /// Trigger the system download sheet for the configured pair.
    func startDownload() {
        guard let pair else { phase = .done; return }
        generation += 1
        phase = .downloading
        // A fresh Configuration makes `.translationTask` run prepareTranslation().
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: pair.source),
            target: Locale.Language(identifier: pair.target)
        )
    }

    /// Called once `prepareTranslation()` returns (whether it completed or the
    /// person dismissed the sheet). Settle on the *verified* status rather than
    /// trusting that the call returned: `supported` here means "still not
    /// installed", i.e. the sheet was dismissed without downloading.
    func didFinishPreparing(gen: Int) async {
        guard gen == generation, phase == .downloading, let pair else { return }
        let status = await statusOf(pair)
        guard gen == generation, phase == .downloading else { return }
        configuration = nil
        phase = Self.phase(for: status)
    }

    func fail(gen: Int) {
        guard gen == generation, phase == .downloading else { return }
        phase = .failed
        configuration = nil
    }

    // MARK: - Availability

    private func statusOf(_ pair: LanguagePair) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: pair.source),
            to: Locale.Language(identifier: pair.target)
        )
    }

    private static func phase(for status: LanguageAvailability.Status) -> Phase {
        switch status {
        case .installed: return .done       // assets present — ready offline
        case .supported: return .idle       // supported but not downloaded yet
        case .unsupported: return .unsupported
        @unknown default: return .idle
        }
    }
}

@available(macOS 15, *)
private struct AppleLanguageDownloadButtonBody: View {
    let target: TranslationLanguage
    let secondTarget: TranslationLanguage

    @State private var model = AppleDownloadModel()

    /// One representative direction is enough (assets are per-language). Nil when
    /// both configured languages are the same.
    private var pair: AppleDownloadModel.LanguagePair? {
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
        case .idle:
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
        case .done:
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

/// Request the download for the configured pair, then hand back to the model to
/// verify the real result. Runs from a `nonisolated` context so `session` never
/// crosses the MainActor; results hop back via `await`. The captured `generation`
/// lets the model ignore a callback from a run a newer one has superseded.
@available(macOS 15, *)
private nonisolated func runApplePrepare(_ session: TranslationSession,
                                         model: AppleDownloadModel) async {
    let gen = await model.currentGeneration
    do {
        // Presents the system download sheet when assets aren't installed, returns
        // immediately when they are, and — importantly — also returns *without
        // error* when the person dismisses the sheet without downloading, which is
        // why the model re-checks real availability instead of trusting this call.
        try await session.prepareTranslation()
        await model.didFinishPreparing(gen: gen)
    } catch is CancellationError {
        // Superseded by a newer configuration; the next task drives the state.
    } catch let error as CocoaError where error.code == .userCancelled {
        // Progress UI dismissed mid-download — verify what actually installed.
        await model.didFinishPreparing(gen: gen)
    } catch {
        await model.fail(gen: gen)
    }
}
#endif
