import Foundation
import Observation
#if canImport(Translation)
import Translation
#endif

#if canImport(Translation)
/// Owns one Apple translate run: the immutable text/language snapshot, the
/// `TranslationSession.Configuration` that `.translationTask` observes, and the
/// card render state. Only the generation that armed the request may publish
/// success, failure, or a user-cancelled idle reset. A cancelled or superseded
/// callback must not settle a newer run (or write history via the caller).
///
/// Same-pair reruns call `invalidate()` on the existing configuration — two
/// freshly constructed same-language values are `Equatable` at `version == 0`,
/// so replacing the struct does not retrigger Apple's task. A different pair
/// writes `source`/`target` so equality changes through the languages themselves.
@available(macOS 15, *)
@MainActor
@Observable
final class AppleTranslationRequestState {
    /// Immutable identity captured when a run is armed. `source == nil` is
    /// official auto-detect, not an unsupported pairing.
    struct Request: Sendable, Equatable {
        let generation: Int
        let text: String
        let source: TranslationLanguage?
        let target: TranslationLanguage
        let runID: String
        let runToken: Int
    }

    /// Sendable completion the nonisolated `.translationTask` runner maps to
    /// before hopping back. `cancelled` never writes, even for the owning
    /// generation — recovery is a later `beginRequest`, not a stale reset.
    enum Completion: Sendable, Equatable {
        case success(String)
        case failureMessage(String)
        case userCancelled
        case cancelled
    }

    enum ApplyOutcome: Equatable {
        case ignored
        case publishedSuccess
        case publishedFailure
        case resetToIdle
    }

    private(set) var configuration: TranslationSession.Configuration?
    private(set) var currentRequest: Request?
    private(set) var generation = 0

    private(set) var output: String = ""
    private(set) var status: TranslationResult.Status = .idle
    private(set) var errorMessage: String?

    /// Arm a run from an explicit Enter (or the pending-Enter continuation once
    /// a pack becomes installed). Empty / whitespace-only input withdraws any
    /// armed request so a late callback cannot republish.
    func beginRequest(text: String,
                      source: TranslationLanguage?,
                      target: TranslationLanguage,
                      runID: String,
                      runToken: Int) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            clearArmedTranslation()
            return
        }
        generation += 1
        currentRequest = Request(
            generation: generation,
            text: text,
            source: source,
            target: target,
            runID: runID,
            runToken: runToken
        )
        beginLoading()
        // Snapshot is stored before the configuration mutation so a newly
        // scheduled `.translationTask` reads this generation, not a previous one.
        armConfiguration(
            sourceLocale: source.map { Locale.Language(identifier: $0.code) },
            targetLocale: Locale.Language(identifier: target.code)
        )
    }

    /// Empty input, or a run while the pack is not installed: drop the armed
    /// configuration, hide the result card, and retire the generation.
    func clearArmedTranslation() {
        generation += 1
        currentRequest = nil
        configuration = nil
        reset()
    }

    /// Classify a `session.translate` result off the MainActor so only a
    /// `Sendable` completion crosses isolation.
    nonisolated static func completion(for result: Result<String, Error>) -> Completion {
        switch result {
        case .success(let text):
            return .success(text)
        case .failure(let error):
            if error is CancellationError {
                return .cancelled
            }
            if let cocoa = error as? CocoaError, cocoa.code == .userCancelled {
                return .userCancelled
            }
            return .failureMessage(error.localizedDescription)
        }
    }

    /// Publish only when `generation` is still the armed owner. Stale and
    /// cancelled completions return `.ignored` without touching render state.
    func apply(_ completion: Completion, generation: Int) -> ApplyOutcome {
        guard generation == self.generation, currentRequest != nil else {
            return .ignored
        }
        switch completion {
        case .success(let text):
            succeed(text)
            return .publishedSuccess
        case .failureMessage(let message):
            fail(message)
            return .publishedFailure
        case .userCancelled:
            reset()
            return .resetToIdle
        case .cancelled:
            return .ignored
        }
    }

    // MARK: - Configuration

    private func armConfiguration(sourceLocale: Locale.Language?,
                                  targetLocale: Locale.Language) {
        if var existing = configuration {
            if existing.source == sourceLocale, existing.target == targetLocale {
                existing.invalidate()
            } else {
                existing.source = sourceLocale
                existing.target = targetLocale
            }
            configuration = existing
        } else {
            configuration = TranslationSession.Configuration(
                source: sourceLocale,
                target: targetLocale
            )
        }
    }

    // MARK: - Render state

    private func beginLoading() {
        status = .loading
        output = ""
        errorMessage = nil
    }

    private func reset() {
        status = .idle
        output = ""
        errorMessage = nil
    }

    private func succeed(_ text: String) {
        output = text
        status = .success
    }

    private func fail(_ message: String) {
        errorMessage = message
        status = .failure
    }
}
#endif
