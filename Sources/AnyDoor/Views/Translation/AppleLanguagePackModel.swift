import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

#if canImport(Translation)
/// Shared availability + download driver for Apple's on-device translation, used
/// by both the settings download button and the Apple result card. Apple's
/// translation assets are per-language and shared system-wide, so downloading a
/// single direction (`source → target`) installs both languages and makes the
/// reverse direction available too — no need to prepare both ways. A `generation`
/// token supersedes stale async work when the configured languages change
/// mid-flight. `@MainActor @Observable` so the UI binds to `phase` and the
/// `nonisolated` task closure can publish back via `await`.
@available(macOS 15, *)
@MainActor
@Observable
final class AppleLanguagePackModel {
    enum Phase: Equatable { case checking, needsDownload, downloading, installed, unsupported, failed }

    private(set) var phase: Phase = .checking
    private(set) var configuration: TranslationSession.Configuration?
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
        guard let pair else { phase = .installed; return }
        phase = .checking
        let status = await statusOf(pair)
        guard gen == generation else { return }
        phase = Self.phase(for: status)
    }

    /// Trigger the system download sheet for the configured pair.
    func startDownload() {
        guard let pair else { phase = .installed; return }
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
        case .installed: return .installed      // assets present — ready offline
        case .supported: return .needsDownload  // supported but not downloaded yet
        case .unsupported: return .unsupported
        @unknown default: return .needsDownload
        }
    }
}

/// Request the download for the configured pair, then hand back to the model to
/// verify the real result. Runs from a `nonisolated` context so `session` never
/// crosses the MainActor; results hop back via `await`. The captured `generation`
/// lets the model ignore a callback from a run a newer one has superseded.
@available(macOS 15, *)
nonisolated func runApplePrepare(_ session: TranslationSession,
                                 model: AppleLanguagePackModel) async {
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
