import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Trailing control in the Apple service settings row that proactively downloads
/// the on-device translation assets for the two configured target languages via
/// `prepareTranslation()`, so the first real translation doesn't have to stop and
/// fetch a language pack. On macOS 14 (no Translation API) it renders nothing,
/// mirroring `AppleTranslationCard`.
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
/// Drives the proactive download. Each `.translationTask` session binds to a
/// single source/target pair, so the two configured directions are prepared one
/// at a time by draining `pending` and re-pointing `configuration` at the next
/// pair. `@MainActor @Observable` so the SwiftUI control binds to `phase` and the
/// `nonisolated` task closure can publish back via `await`.
@available(macOS 15, *)
@MainActor
@Observable
private final class AppleDownloadModel {
    enum Phase: Equatable { case idle, downloading, done, failed }

    var phase: Phase = .idle
    var configuration: TranslationSession.Configuration?
    /// Remaining (source, target) code pairs still to prepare, drained one per
    /// session because a session only covers its own configured pair.
    private var pending: [(source: String, target: String)] = []

    func start(pairs: [(source: String, target: String)]) {
        guard !pairs.isEmpty else { phase = .done; return }
        phase = .downloading
        pending = pairs
        advance()
    }

    /// Move on to the next pending direction, or settle on `.done` when drained.
    /// Guarded on `.downloading` so a late callback from a task cancelled by a
    /// `reset()` (e.g. the configured languages changed mid-download) can't revive
    /// a stale state.
    func advance() {
        guard phase == .downloading else { return }
        guard !pending.isEmpty else {
            phase = .done
            configuration = nil
            return
        }
        let next = pending.removeFirst()
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: next.source),
            target: Locale.Language(identifier: next.target)
        )
    }

    func fail() {
        guard phase == .downloading else { return }
        phase = .failed
        pending = []
        configuration = nil
    }

    /// Drop back to idle and tear down any in-flight session. Used both when the
    /// person declines/dismisses the system download sheet (a choice, not a
    /// failure) and when the configured languages change, invalidating a prior
    /// "downloaded" result.
    func reset() {
        phase = .idle
        pending = []
        configuration = nil
    }
}

@available(macOS 15, *)
private struct AppleLanguageDownloadButtonBody: View {
    let target: TranslationLanguage
    let secondTarget: TranslationLanguage

    @State private var model = AppleDownloadModel()

    var body: some View {
        control
            .font(.callout)
            .help(L(.settingsTranslationDownloadLanguagesHelp, target.displayName(), secondTarget.displayName()))
            // Changing either configured language invalidates a prior result, so
            // reset back to the download prompt rather than showing a stale state.
            .onChange(of: target) { _, _ in model.reset() }
            .onChange(of: secondTarget) { _, _ in model.reset() }
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
        case .idle:
            Button { startDownload() } label: {
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
        case .failed:
            Button { startDownload() } label: {
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

    private func startDownload() {
        // Same language both ways has nothing to fetch; treat it as already done.
        guard target.code != secondTarget.code else {
            model.start(pairs: [])
            return
        }
        model.start(pairs: [
            (source: secondTarget.code, target: target.code),
            (source: target.code, target: secondTarget.code),
        ])
    }
}

/// Request the download for one configured pair. Runs from a `nonisolated`
/// context so `session` never crosses the MainActor; results hop back via `await`.
@available(macOS 15, *)
private nonisolated func runApplePrepare(_ session: TranslationSession,
                                         model: AppleDownloadModel) async {
    do {
        // Presents the system download sheet when the assets aren't installed,
        // and returns immediately when they already are.
        try await session.prepareTranslation()
        await model.advance()
    } catch is CancellationError {
        // Superseded by a newer configuration; the next task drives the state.
    } catch let error as CocoaError where error.code == .userCancelled {
        await model.reset()
    } catch {
        await model.fail()
    }
}
#endif
