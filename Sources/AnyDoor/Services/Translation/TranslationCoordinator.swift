import Foundation
import Observation

/// Fans the same input out to every configured stream provider concurrently and
/// stacks each as a `TranslationResult` card. Each provider runs in its own task
/// so one failure never knocks out the others. `@MainActor @Observable` so the
/// SwiftUI panel binds directly to `results`.
@MainActor
@Observable
final class TranslationCoordinator {
    static let shared = TranslationCoordinator()

    var inputText: String = ""
    var source: TranslationLanguage?            // nil = auto-detect
    var target: TranslationLanguage
    private(set) var detectedSource: TranslationLanguage?
    private(set) var results: [TranslationResult] = []
    /// Latest successful Apple on-device translation for the current run, keyed by
    /// runToken so a stale value from a previous run is ignored. The Apple card
    /// publishes here (it lives outside `results`) so the panel's auto-speak path
    /// can include it.
    private(set) var appleResult: (runToken: Int, text: String)?

    /// Bumped on every `translate()` invocation. Views (e.g. the Apple card,
    /// which binds to Apple's API directly instead of going through a provider)
    /// observe this so they translate only on an explicit run, not per keystroke;
    /// the panel also resets its auto-speak guard on each change.
    private(set) var runToken: Int = 0

    /// Set by the app once the ModelContainer is ready; nil in tests.
    var history: TranslationHistoryStore?

    private let settings: TranslationSettings
    private let makeProviders: @MainActor () -> [any TranslationProvider]
    private var tasks: [String: Task<Void, Never>] = [:]

    init(settings: TranslationSettings = .shared,
         makeProviders: (@MainActor () -> [any TranslationProvider])? = nil) {
        self.settings = settings
        self.target = settings.targetLanguage
        if let makeProviders {
            self.makeProviders = makeProviders
        } else {
            self.makeProviders = { TranslationProviderFactory.makeStreamProviders(settings: settings) }
        }
    }

    func updateDetection() {
        detectedSource = LanguageDetector.detect(inputText)
    }

    /// If the (chosen or detected) source already equals the target, translate to
    /// the configured second target instead so a "same language" request still
    /// yields something useful.
    func effectiveTarget() -> TranslationLanguage {
        let effectiveSource = source ?? detectedSource
        if effectiveSource == target {
            return settings.secondTargetLanguage
        }
        return target
    }

    func translate() {
        runToken &+= 1
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            return
        }
        cancel()
        updateDetection()

        let providers = makeProviders()
        let request = TranslationRequest(text: text, source: source, target: effectiveTarget())

        results = providers.map { TranslationResult.idle($0.id) }

        let token = runToken
        for provider in providers {
            let id = provider.id
            tasks[id] = Task { [weak self] in
                await self?.run(provider: provider, request: request, sourceText: text)
                // Drop the completed entry, but only if a newer translate() hasn't
                // already replaced it (the supersede/cancel race): cancel() clears
                // the whole dict and a fresh run installs a new task + bumps
                // runToken, so guard on the captured token.
                guard let self, self.runToken == token else { return }
                self.tasks[id] = nil
            }
        }
    }

    private func run(provider: any TranslationProvider,
                     request: TranslationRequest,
                     sourceText: String) async {
        setStatus(.loading, for: provider.id)
        do {
            for try await chunk in provider.translate(request) {
                if Task.isCancelled { return }
                switch chunk {
                case .detected(let language):
                    update(provider.id) { $0.detected = language }
                case .delta(let piece):
                    update(provider.id) {
                        $0.status = .streaming
                        $0.text += piece
                    }
                case .final(let full):
                    update(provider.id) {
                        if !full.isEmpty { $0.text = full }
                    }
                }
            }
            if Task.isCancelled { return }
            update(provider.id) { $0.status = .success }
            recordSuccess(provider: provider, request: request, sourceText: sourceText)
        } catch is CancellationError {
            // Silent: a fresh translate() superseded this run.
        } catch {
            if Task.isCancelled { return }
            update(provider.id) {
                $0.status = .failure
                $0.errorMessage = (error as? TranslationProviderError).map(String.init(describing:))
                    ?? error.localizedDescription
            }
        }
    }

    private func recordSuccess(provider: any TranslationProvider,
                               request: TranslationRequest,
                               sourceText: String) {
        guard let history,
              let result = results.first(where: { $0.serviceID == provider.id }),
              !result.text.isEmpty else { return }
        let serviceName = settings.services.first(where: { $0.id == provider.id })?.displayName ?? provider.id
        history.record(
            sourceText: sourceText,
            translatedText: result.text,
            source: request.source ?? result.detected ?? detectedSource,
            target: request.target,
            serviceID: provider.id,
            serviceName: serviceName,
            retention: settings.historyRetention)
    }

    /// Note a successful Apple on-device translation. The Apple card binds to
    /// Apple's API directly (it is not a `TranslationProvider`), so it can't flow
    /// through `run()`/`recordSuccess`; it calls this with its own output instead.
    /// Publishes `appleResult` (so the panel's auto-speak can include it) and
    /// records to history through the same store the coordinator uses.
    func noteAppleSuccess(serviceID: String,
                          serviceName: String,
                          sourceText: String,
                          translatedText: String,
                          target: TranslationLanguage) {
        guard !translatedText.isEmpty else { return }
        appleResult = (runToken, translatedText)
        guard let history,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        history.record(
            sourceText: sourceText,
            translatedText: translatedText,
            source: source ?? detectedSource,
            target: target,
            serviceID: serviceID,
            serviceName: serviceName,
            retention: settings.historyRetention)
    }

    func cancel() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    func swapLanguages() {
        let oldSource = source ?? detectedSource ?? target
        source = target
        target = oldSource
    }

    func prefill(_ text: String, autoTranslate: Bool) {
        inputText = text
        updateDetection()
        if autoTranslate {
            translate()
        }
    }

    // MARK: - Result mutation helpers

    private func setStatus(_ status: TranslationResult.Status, for id: String) {
        update(id) { $0.status = status }
    }

    private func update(_ id: String, _ mutate: (inout TranslationResult) -> Void) {
        guard let index = results.firstIndex(where: { $0.serviceID == id }) else { return }
        var copy = results[index]
        mutate(&copy)
        results[index] = copy
    }
}
