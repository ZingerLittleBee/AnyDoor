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

        for provider in providers {
            let id = provider.id
            tasks[id] = Task { [weak self] in
                await self?.run(provider: provider, request: request, sourceText: text)
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
            serviceName: serviceName)
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
