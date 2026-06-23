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
    /// The request captured by the most recent `translate()`. `translateOne`
    /// reuses it so a manually-expanded service translates the same text/target
    /// its sibling cards used this run.
    private(set) var currentRequest: TranslationRequest?
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

    /// Brackets the synchronous provider build, which can read the Keychain and
    /// raise a blocking system credential prompt. The window controller installs
    /// this so its Spotlight-style floating panel doesn't auto-dismiss when that
    /// prompt steals key focus; the default just runs the work (tests / headless).
    var withKeychainPromptGuard: @MainActor (() -> Void) -> Void = { $0() }

    /// Installed by the window controller to suspend / re-arm the panel's
    /// auto-dismiss around ASYNC work that can surface a system sheet (e.g.
    /// Apple's on-device language-pack download), which steals key focus like the
    /// keychain prompt but fires off the main thread after `translate()` has
    /// already returned. Defaults are no-ops (tests / headless).
    var onBeginSystemSheet: @MainActor () -> Void = {}
    var onEndSystemSheet: @MainActor () -> Void = {}

    /// Bracket async system-sheet work (see `onBeginSystemSheet`). The Apple card
    /// calls these around its bare `session.translate` only when a language pack
    /// must be downloaded, so the panel survives the download sheet.
    func beginSystemSheet() { onBeginSystemSheet() }
    func endSystemSheet() { onEndSystemSheet() }

    private let settings: TranslationSettings
    private let makeProviders: @MainActor () -> [any TranslationProvider]
    private let makeProvider: @MainActor (TranslationServiceConfig) -> (any TranslationProvider)?
    private var tasks: [String: Task<Void, Never>] = [:]

    init(settings: TranslationSettings = .shared,
         makeProviders: (@MainActor () -> [any TranslationProvider])? = nil,
         makeProvider: (@MainActor (TranslationServiceConfig) -> (any TranslationProvider)?)? = nil) {
        self.settings = settings
        self.target = settings.targetLanguage
        if let makeProviders {
            self.makeProviders = makeProviders
        } else {
            self.makeProviders = { TranslationProviderFactory.makeStreamProviders(settings: settings) }
        }
        self.makeProvider = makeProvider ?? { TranslationProviderFactory.makeStreamProvider(for: $0) }
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
            currentRequest = nil
            return
        }
        cancel()
        updateDetection()

        // Build providers inside the guard: an LLM provider reads its API key from
        // the Keychain here, which can synchronously surface a system credential
        // prompt that would otherwise dismiss the floating panel.
        var providers: [any TranslationProvider] = []
        withKeychainPromptGuard { providers = makeProviders() }
        let request = TranslationRequest(text: text, source: source, target: effectiveTarget())
        currentRequest = request

        // Manual (collapsed-by-default) services get a deferred placeholder card
        // with no task; they translate only when the user expands them. The
        // factory already excludes them from the auto `providers` above.
        var newResults = settings.enabledServicesInOrder
            .filter { $0.startsManual }
            .map { TranslationResult.deferred($0.id) }
        newResults.append(contentsOf: providers.map { TranslationResult.idle($0.id) })
        results = newResults

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

    /// Translate a single manual service on demand, reusing the current run's
    /// request. No-op unless that service currently holds a `.deferred` result
    /// (guards against double-trigger / already-running / already-done).
    func translateOne(serviceID: String) {
        guard let request = currentRequest,
              let config = settings.services.first(where: { $0.id == serviceID }),
              results.first(where: { $0.serviceID == serviceID })?.status == .deferred else {
            return
        }

        var provider: (any TranslationProvider)?
        withKeychainPromptGuard { provider = makeProvider(config) }
        guard let provider else {
            update(serviceID) {
                $0.status = .failure
                $0.errorMessage = L(.translationErrorMissingConfig)
            }
            return
        }

        // Show the spinner immediately on expand, before the task's first hop.
        update(serviceID) { $0.status = .loading }
        let token = runToken
        tasks[serviceID] = Task { [weak self] in
            await self?.run(provider: provider, request: request, sourceText: request.text)
            guard let self, self.runToken == token else { return }
            self.tasks[serviceID] = nil
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
                $0.errorMessage = translationErrorMessage(error)
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

    /// Bumped whenever the input text is set programmatically (e.g. prefill from
    /// screenshot / selection / history), so the editor adopts it even while it
    /// holds focus — its update guard otherwise skips external writes during
    /// editing to protect IME composition.
    private(set) var inputSetToken: Int = 0

    func prefill(_ text: String, autoTranslate: Bool) {
        inputText = text
        inputSetToken &+= 1
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
