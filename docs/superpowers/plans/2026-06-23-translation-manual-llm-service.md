# Manual (collapsed-by-default) LLM translation services — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an `openAICompatible` (LLM) translation service be configured to start collapsed and *not* auto-translate; it translates only when the user expands its card, and every new run resets it to collapsed.

**Architecture:** A manual service produces a real result card in a new `.deferred` status with no task started. Expanding the card calls `TranslationCoordinator.translateOne(serviceID:)`, which builds just that one provider and runs it against the run's captured request. `results` stays the single source of truth for stream cards; no LLM call happens until expand. Apple / Google / Bing and the Apple card path are untouched.

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftUI + AppKit, SwiftData (unaffected here), `TranslationSettings` (UserDefaults JSON), `L10n` + `.xcstrings` catalog (compiled by the build-tool plugin), XCTest.

**Spec:** `docs/superpowers/specs/2026-06-23-translation-manual-llm-service-design.md`

---

## File Structure

**Modify:**
- `Sources/AnyDoor/Models/Translation/TranslationServiceConfig.swift` — add `manualMode` field + `startsManual`.
- `Sources/AnyDoor/Models/Translation/TranslationExchange.swift` — add `.deferred` status + `deferred(_:)` factory.
- `Sources/AnyDoor/Services/Translation/TranslationProviderFactory.swift` — extract `makeStreamProvider(for:)`, exclude manual in `makeStreamProviders`.
- `Sources/AnyDoor/Services/Translation/TranslationCoordinator.swift` — `currentRequest`, `makeProvider` injection, deferred results in `translate()`, new `translateOne(serviceID:)`.
- `Sources/AnyDoor/Utilities/L10n.swift` — 3 new key cases.
- `Sources/AnyDoor/Resources/Localizable.xcstrings` — 3 new entries (en + zh-Hans).
- `Sources/AnyDoor/Views/Translation/TranslationServiceCard.swift` — deferred rendering, collapse-on-run, expand-triggers-translate.
- `Sources/AnyDoor/Views/Translation/TranslationView.swift` — pass `onExpandDeferred` into the card.
- `Sources/AnyDoor/Views/TranslationSettingsView.swift` — manual-mode toggle in the editor sheet.

**Test:**
- `Tests/AnyDoorTests/TranslationServiceConfigTests.swift`
- `Tests/AnyDoorTests/TranslationExchangeTests.swift`
- `Tests/AnyDoorTests/TranslationProviderFactoryTests.swift`
- `Tests/AnyDoorTests/TranslationCoordinatorTests.swift`

**Commit policy:** Commit after each task. Local commits only — **never push** (user constraint). Conventional Commits, English, no `Co-Authored-By`, no AI-watermark trailers, strip any `@`.

---

### Task 1: Model — `manualMode` field + `startsManual`

**Files:**
- Modify: `Sources/AnyDoor/Models/Translation/TranslationServiceConfig.swift`
- Test: `Tests/AnyDoorTests/TranslationServiceConfigTests.swift`

- [ ] **Step 1: Write the failing tests**

Append these methods inside `final class TranslationServiceConfigTests` (before the closing brace):

```swift
    // MARK: - manualMode / startsManual

    func testManualModeDefaultsToNilAndStartsManualFalse() {
        let config = TranslationServiceConfig(
            id: "x", kind: .openAICompatible, displayName: "X", iconName: "brain",
            enabled: true, order: 0, baseURL: "https://a.com/v1", model: "m",
            promptTemplate: nil)
        XCTAssertNil(config.manualMode)
        XCTAssertFalse(config.startsManual)
    }

    func testStartsManualTrueOnlyForLLMWithManualMode() {
        var llm = TranslationServiceConfig(
            id: "llm", kind: .openAICompatible, displayName: "L", iconName: "brain",
            enabled: true, order: 0, baseURL: "https://a.com/v1", model: "m",
            promptTemplate: nil)
        llm.manualMode = true
        XCTAssertTrue(llm.startsManual)

        var google = TranslationServiceConfig(
            id: "g", kind: .googleFree, displayName: "G", iconName: "globe",
            enabled: true, order: 0, baseURL: nil, model: nil, promptTemplate: nil)
        google.manualMode = true // ignored for non-LLM kinds
        XCTAssertFalse(google.startsManual)
    }

    func testManualModeCodableRoundTripAndLegacyDecodesNil() throws {
        var config = TranslationServiceConfig(
            id: "llm", kind: .openAICompatible, displayName: "L", iconName: "brain",
            enabled: true, order: 0, baseURL: "https://a.com/v1", model: "m",
            promptTemplate: nil)
        config.manualMode = true
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(TranslationServiceConfig.self, from: data), config)

        // Legacy JSON (pre-feature) omits the key; must decode to nil, not throw.
        let legacy = #"{"id":"old","kind":"openAICompatible","displayName":"O","iconName":"brain","enabled":true,"order":0}"#
        let decoded = try JSONDecoder().decode(TranslationServiceConfig.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.manualMode)
        XCTAssertFalse(decoded.startsManual)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "TranslationServiceConfigTests/testManualModeCodableRoundTripAndLegacyDecodesNil"`
Expected: FAIL to compile — `value of type 'TranslationServiceConfig' has no member 'manualMode'`.

- [ ] **Step 3: Add the field and computed property**

In `TranslationServiceConfig.swift`, add the stored property immediately after `promptTemplate` (keep it last so the memberwise initializer gives it a default):

```swift
    /// `openAICompatible` only: when true the service starts collapsed and does
    /// not auto-translate on a run; its card translates only when expanded.
    /// Optional so legacy stored JSON (which lacks the key) still decodes — a
    /// non-optional property would make synthesized Decodable throw on the
    /// missing key. Mirrors the other optional LLM fields.
    var manualMode: Bool?
```

Then add this computed property inside the `extension TranslationServiceConfig` block (e.g. right after `isValidBaseURL`):

```swift
    /// Whether this service starts collapsed and defers translation until the
    /// user expands its card. Only `openAICompatible` honors `manualMode`.
    var startsManual: Bool {
        kind == .openAICompatible && (manualMode ?? false)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "TranslationServiceConfigTests"`
Expected: PASS (all existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/Translation/TranslationServiceConfig.swift Tests/AnyDoorTests/TranslationServiceConfigTests.swift
git commit -m "feat(translation): add manualMode flag to service config"
```

---

### Task 2: Result model — `.deferred` status

**Files:**
- Modify: `Sources/AnyDoor/Models/Translation/TranslationExchange.swift`
- Test: `Tests/AnyDoorTests/TranslationExchangeTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside `TranslationExchangeTests` (before its closing brace):

```swift
    func testDeferredFactoryProducesDeferredStatus() {
        let result = TranslationResult.deferred("svc")
        XCTAssertEqual(result.status, .deferred)
        XCTAssertEqual(result.serviceID, "svc")
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertNil(result.errorMessage)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter "TranslationExchangeTests/testDeferredFactoryProducesDeferredStatus"`
Expected: FAIL to compile — `type 'TranslationResult' has no member 'deferred'` and `.deferred` is not a member of `Status`.

- [ ] **Step 3: Add the status case and factory**

In `TranslationExchange.swift`, add `case deferred` to the `Status` enum (after `case idle`):

```swift
    enum Status: Sendable, Equatable {
        case idle
        /// Manual (collapsed-by-default) service: shown but not yet translated.
        case deferred
        case loading
        case streaming
        case success
        case failure
    }
```

Then add a factory next to `idle(_:)`:

```swift
    /// A deferred (manual, not-yet-translated) result for the given service.
    static func deferred(_ serviceID: String) -> TranslationResult {
        TranslationResult(
            serviceID: serviceID,
            status: .deferred,
            text: "",
            detected: nil,
            errorMessage: nil
        )
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter "TranslationExchangeTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/Translation/TranslationExchange.swift Tests/AnyDoorTests/TranslationExchangeTests.swift
git commit -m "feat(translation): add deferred result status"
```

---

### Task 3: Provider factory — single-config builder + exclude manual

**Files:**
- Modify: `Sources/AnyDoor/Services/Translation/TranslationProviderFactory.swift`
- Test: `Tests/AnyDoorTests/TranslationProviderFactoryTests.swift`

- [ ] **Step 1: Write the failing tests**

In `TranslationProviderFactoryTests.swift`, extend `tearDown()` to also delete the new ids (add the three `deleteAPIKey` lines):

```swift
    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.deleteAPIKey(for: "llm-keyed")
        keychain.deleteAPIKey(for: "llm-keyless")
        keychain.deleteAPIKey(for: "single-llm")
        keychain.deleteAPIKey(for: "manual")
        keychain.deleteAPIKey(for: "auto")
        super.tearDown()
    }
```

Then append these test methods (before the class closing brace):

```swift
    func testMakeStreamProviderBuildsSingleSkipsAppleAndIncomplete() {
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.setAPIKey("sk-1", for: "single-llm")

        XCTAssertNil(TranslationProviderFactory.makeStreamProvider(
            for: makeConfig(id: "apple", kind: .apple, order: 0), keychain: keychain))

        XCTAssertNotNil(TranslationProviderFactory.makeStreamProvider(
            for: makeConfig(id: "google", kind: .googleFree, order: 0), keychain: keychain))

        XCTAssertNotNil(TranslationProviderFactory.makeStreamProvider(
            for: makeConfig(id: "single-llm", kind: .openAICompatible, order: 0,
                            baseURL: "https://api.example.com/v1", model: "gpt-x"),
            keychain: keychain))

        // Incomplete LLM config (no model) -> nil
        XCTAssertNil(TranslationProviderFactory.makeStreamProvider(
            for: makeConfig(id: "single-llm", kind: .openAICompatible, order: 0,
                            baseURL: "https://api.example.com/v1", model: nil),
            keychain: keychain))
    }

    func testMakeStreamProvidersExcludesManualServices() {
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.setAPIKey("sk-1", for: "manual")
        keychain.setAPIKey("sk-2", for: "auto")
        var manual = makeConfig(id: "manual", kind: .openAICompatible, order: 0,
                                baseURL: "https://api.example.com/v1", model: "gpt-x")
        manual.manualMode = true
        let auto = makeConfig(id: "auto", kind: .openAICompatible, order: 1,
                              baseURL: "https://api.example.com/v1", model: "gpt-x")
        let settings = makeSettings([manual, auto])
        let providers = TranslationProviderFactory.makeStreamProviders(
            settings: settings, keychain: keychain)
        XCTAssertEqual(providers.map(\.id), ["auto"])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "TranslationProviderFactoryTests/testMakeStreamProviderBuildsSingleSkipsAppleAndIncomplete"`
Expected: FAIL to compile — `type 'TranslationProviderFactory' has no member 'makeStreamProvider'`.

- [ ] **Step 3: Refactor the factory**

Replace the entire body of `enum TranslationProviderFactory { … }` in `TranslationProviderFactory.swift` with:

```swift
enum TranslationProviderFactory {
    /// Build the concrete stream provider for a single config, or `nil` when it
    /// has no stream provider (`apple` is rendered by its own card) or is an
    /// incomplete `openAICompatible` (no key / missing baseURL / missing model).
    /// Ignores `manualMode` — an explicit single build always builds.
    @MainActor
    static func makeStreamProvider(
        for config: TranslationServiceConfig,
        keychain: TranslationKeychainStore = TranslationKeychainStore(),
        session: URLSession = .shared
    ) -> (any TranslationProvider)? {
        switch config.kind {
        case .apple:
            return nil // rendered by AppleTranslationCard, not a stream provider
        case .googleFree:
            return GoogleFreeTranslationProvider(id: config.id, session: session)
        case .bingFree:
            return BingFreeTranslationProvider(id: config.id, session: session)
        case .openAICompatible:
            guard let key = keychain.apiKey(for: config.id),
                  !key.isEmpty,
                  let baseURL = config.baseURL, !baseURL.isEmpty,
                  let model = config.model, !model.isEmpty else {
                return nil // no key or incomplete config -> skip silently
            }
            _ = (baseURL, model) // config carries them; provider reads from config
            return OpenAICompatibleProvider(config: config, apiKey: key, session: session)
        }
    }

    /// Build the auto fan-out providers: enabled, non-apple, **non-manual**
    /// services in order. Manual services are excluded — they translate on
    /// demand via `TranslationCoordinator.translateOne`, not the fan-out.
    @MainActor
    static func makeStreamProviders(
        settings: TranslationSettings,
        keychain: TranslationKeychainStore = TranslationKeychainStore(),
        session: URLSession = .shared
    ) -> [any TranslationProvider] {
        settings.enabledServicesInOrder
            .filter { !$0.startsManual }
            .compactMap { makeStreamProvider(for: $0, keychain: keychain, session: session) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "TranslationProviderFactoryTests"`
Expected: PASS (existing 3 + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Translation/TranslationProviderFactory.swift Tests/AnyDoorTests/TranslationProviderFactoryTests.swift
git commit -m "refactor(translation): add single-provider builder, exclude manual from fan-out"
```

---

### Task 4: Coordinator — deferred results + `translateOne`

**Files:**
- Modify: `Sources/AnyDoor/Services/Translation/TranslationCoordinator.swift`
- Test: `Tests/AnyDoorTests/TranslationCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

In `TranslationCoordinatorTests.swift`, add a helper for a manual-service coordinator and two tests. Insert the helper after `makeCoordinator(_:defaultsSuite:)`:

```swift
    /// A coordinator whose settings contain a single manual LLM service and whose
    /// single-provider builder returns `scripted` for that id.
    private func makeManualCoordinator(scripted: ScriptedProvider)
    -> TranslationCoordinator {
        let d = UserDefaults(suiteName: "translation.coord.\(UUID().uuidString)")!
        let settings = TranslationSettings(defaults: d)
        var manual = TranslationServiceConfig(
            id: scripted.id, kind: .openAICompatible, displayName: "LLM", iconName: "brain",
            enabled: true, order: 0, baseURL: "https://api.example.com/v1", model: "gpt-x",
            promptTemplate: TranslationServiceConfig.defaultPromptTemplate)
        manual.manualMode = true
        settings.setServices([manual])
        return TranslationCoordinator(
            settings: settings,
            makeProviders: { [] },
            makeProvider: { $0.id == scripted.id ? scripted : nil })
    }
```

Then append these tests (before the class closing brace):

```swift
    func testManualServiceGetsDeferredResultAndStartsNoTask() async {
        let scripted = ScriptedProvider(id: "llm", kind: .openAICompatible, chunks: [.final("你好")])
        let coordinator = makeManualCoordinator(scripted: scripted)
        coordinator.inputText = "Hello"
        coordinator.target = TranslationLanguage.simplifiedChinese
        coordinator.translate()

        XCTAssertEqual(coordinator.results.first(where: { $0.serviceID == "llm" })?.status, .deferred)
        // No task should have run: give any erroneous task time, then re-check.
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(coordinator.results.first(where: { $0.serviceID == "llm" })?.status, .deferred)
        XCTAssertTrue(coordinator.results.first(where: { $0.serviceID == "llm" })?.text.isEmpty ?? false)
    }

    func testTranslateOneRunsADeferredService() async {
        let scripted = ScriptedProvider(id: "llm", kind: .openAICompatible, chunks: [.final("你好")])
        let coordinator = makeManualCoordinator(scripted: scripted)
        coordinator.inputText = "Hello"
        coordinator.target = TranslationLanguage.simplifiedChinese
        coordinator.translate()
        coordinator.translateOne(serviceID: "llm")

        await waitUntil { coordinator.results.first(where: { $0.serviceID == "llm" })?.status == .success }
        XCTAssertEqual(coordinator.results.first(where: { $0.serviceID == "llm" })?.text, "你好")
    }

    func testTranslateOneIsNoOpWithoutADeferredResult() {
        let coordinator = makeCoordinator([])
        // No current request / no deferred entry -> must not crash or change state.
        coordinator.translateOne(serviceID: "nope")
        XCTAssertTrue(coordinator.results.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "TranslationCoordinatorTests/testTranslateOneRunsADeferredService"`
Expected: FAIL to compile — `extra argument 'makeProvider' in call` and `value of type 'TranslationCoordinator' has no member 'translateOne'`.

- [ ] **Step 3: Add the `makeProvider` injection and `currentRequest`**

In `TranslationCoordinator.swift`, add the stored property next to `results` (in the `private(set)` block near the top):

```swift
    /// The request captured by the most recent `translate()`. `translateOne`
    /// reuses it so a manually-expanded service translates the same text/target
    /// its sibling cards used this run.
    private(set) var currentRequest: TranslationRequest?
```

Add the new stored builder next to `makeProviders`:

```swift
    private let makeProvider: @MainActor (TranslationServiceConfig) -> (any TranslationProvider)?
```

Replace the initializer with this version (adds the `makeProvider` parameter with a default):

```swift
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
```

- [ ] **Step 4: Update `translate()` to create deferred results and store the request**

Replace the existing `translate()` method body with:

```swift
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
                guard let self, self.runToken == token else { return }
                self.tasks[id] = nil
            }
        }
    }
```

- [ ] **Step 5: Add `translateOne(serviceID:)`**

Add this method immediately after `translate()`:

```swift
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
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter "TranslationCoordinatorTests"`
Expected: PASS (existing + 3 new).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Services/Translation/TranslationCoordinator.swift Tests/AnyDoorTests/TranslationCoordinatorTests.swift
git commit -m "feat(translation): defer manual services and translate them on demand"
```

---

### Task 5: Localization — 3 new keys

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift`
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`

No unit test (strings are verified by the build compiling the catalog and by the UI tasks referencing the keys).

- [ ] **Step 1: Add the enum cases**

In `L10n.swift`, add two cases right after `settingsTranslationServicePromptMissingText`:

```swift
        case settingsTranslationServiceManualMode = "settings.translation.serviceManualMode"
        case settingsTranslationServiceManualModeHint = "settings.translation.serviceManualModeHint"
```

And add one case right after `translationCollapse`:

```swift
        case translationManualCollapsedHint = "translation.manualCollapsedHint"
```

- [ ] **Step 2: Add the catalog entries**

Run this exact script from the repo root (round-trips the JSON in place, appending the three entries with en + zh-Hans):

```bash
python3 - <<'PY'
import json, collections
p = "Sources/AnyDoor/Resources/Localizable.xcstrings"
d = json.load(open(p), object_pairs_hook=collections.OrderedDict)

def entry(en, zh):
    return collections.OrderedDict([
        ("extractionState", "manual"),
        ("localizations", collections.OrderedDict([
            ("en", {"stringUnit": {"state": "translated", "value": en}}),
            ("zh-Hans", {"stringUnit": {"state": "translated", "value": zh}}),
        ])),
    ])

d["strings"]["settings.translation.serviceManualMode"] = entry(
    "Collapsed by default (translate manually)",
    "默认折叠（手动翻译）")
d["strings"]["settings.translation.serviceManualModeHint"] = entry(
    "When collapsed this service does not auto-translate; expand its card to translate.",
    "折叠状态下不会自动翻译，展开卡片才会翻译。")
d["strings"]["translation.manualCollapsedHint"] = entry(
    "Manual · tap to translate",
    "手动 · 点击翻译")

open(p, "w").write(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
print("done")
PY
```

Expected output: `done`.

- [ ] **Step 3: Verify the catalog and enum compile together**

Run: `swift build`
Expected: `Build complete!` (the `XCStringsCompilerPlugin` compiles the catalog; a malformed JSON or a missing key would fail here).

- [ ] **Step 4: Sanity-check the three keys are present**

Run: `python3 -c "import json;d=json.load(open('Sources/AnyDoor/Resources/Localizable.xcstrings'));print(all(k in d['strings'] for k in ['settings.translation.serviceManualMode','settings.translation.serviceManualModeHint','translation.manualCollapsedHint']))"`
Expected: `True`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(translation): add localization for manual service mode"
```

---

### Task 6: Card — deferred rendering + expand triggers translate

**Files:**
- Modify: `Sources/AnyDoor/Views/Translation/TranslationServiceCard.swift`
- Modify: `Sources/AnyDoor/Views/Translation/TranslationView.swift`

No unit test (SwiftUI/AppKit card). Verified by build + the manual checklist in Step 5.

- [ ] **Step 1: Add the `onExpandDeferred` callback and seed `collapsed` from config**

In `TranslationServiceCard.swift`, replace the stored properties + `@State` block at the top of the struct:

```swift
struct TranslationServiceCard: View {
    let config: TranslationServiceConfig
    let result: TranslationResult
    /// Resolved target language used to pick the TTS voice (the translated text
    /// is in the target language).
    let target: TranslationLanguage
    /// Called when the user expands this card while it is still deferred (manual
    /// service): kicks off its on-demand translation.
    let onExpandDeferred: () -> Void

    @State private var collapsed: Bool

    init(config: TranslationServiceConfig,
         result: TranslationResult,
         target: TranslationLanguage,
         onExpandDeferred: @escaping () -> Void) {
        self.config = config
        self.result = result
        self.target = target
        self.onExpandDeferred = onExpandDeferred
        // Manual services start collapsed; everything else starts expanded.
        _collapsed = State(initialValue: config.startsManual)
    }
```

- [ ] **Step 2: Re-collapse on each new run and surface the manual hint**

In `TranslationServiceCard.swift`, add a `.onChange` to the root `VStack` of `body`. Replace the closing modifiers of `body`:

```swift
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // A new run resets a manual service to .deferred; re-collapse it. Non-manual
        // services never enter .deferred, so their behavior is unchanged.
        .onChange(of: result.status) { _, newStatus in
            if newStatus == .deferred { collapsed = true }
        }
    }
```

In the `header` computed property, add the manual hint right after `statusBadge` (inside the inner `HStack(spacing: 8)`, before `Spacer(minLength: 0)`):

```swift
                statusBadge
                if result.status == .deferred {
                    Text(L(.translationManualCollapsedHint))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
```

- [ ] **Step 3: Trigger translation when a deferred card is expanded**

Replace `toggleCollapsed()` in `TranslationServiceCard.swift`:

```swift
    /// Toggle the body's visibility with a short ease. Expanding a deferred
    /// (manual) card kicks off its on-demand translation.
    private func toggleCollapsed() {
        let willExpand = collapsed
        withAnimation(.easeInOut(duration: 0.22)) { collapsed.toggle() }
        if willExpand, result.status == .deferred {
            onExpandDeferred()
        }
    }
```

- [ ] **Step 4: Handle the `.deferred` case in the body switch**

In `TranslationServiceCard.swift`, add a `.deferred` case to `body(for:)` (it is effectively transient — expanding flips the status to `.loading` synchronously — but the switch must be exhaustive). Change the `case .idle, .loading:` arm to include it:

```swift
        case .idle, .loading, .deferred:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                LocalizedText(.translationTranslating).foregroundStyle(.secondary).font(.callout)
            }
```

(`statusBadge`'s `default: EmptyView()` already covers `.deferred`, so no spinner shows in the collapsed header — correct.)

- [ ] **Step 5: Wire `onExpandDeferred` from the view**

In `TranslationView.swift`, update the `TranslationServiceCard(...)` call inside `resultCards`:

```swift
            } else if let result = coordinator.results.first(where: { $0.serviceID == config.id }) {
                TranslationServiceCard(
                    config: config,
                    result: result,
                    target: target,
                    onExpandDeferred: { coordinator.translateOne(serviceID: config.id) }
                )
            }
```

- [ ] **Step 6: Build, then manually verify**

Run: `swift build`
Expected: `Build complete!`

Run the app (`swift run AnyDoor`) and verify (requires a configured manual LLM service — set up in Task 7, so this manual check can be deferred until after Task 7):
- A manual LLM service appears **collapsed** after pressing Enter, with the "手动 · 点击翻译" hint and no spinner; no network call fires.
- Expanding it shows the spinner then the translation.
- Collapsing and re-expanding shows the cached result without re-translating.
- Pressing Enter again re-collapses it and clears the prior result.
- Non-manual services behave exactly as before.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Views/Translation/TranslationServiceCard.swift Sources/AnyDoor/Views/Translation/TranslationView.swift
git commit -m "feat(translation): render deferred manual cards and translate on expand"
```

---

### Task 7: Settings — manual-mode toggle in the editor sheet

**Files:**
- Modify: `Sources/AnyDoor/Views/TranslationSettingsView.swift`

No unit test (SwiftUI form). Verified by build + manual check.

- [ ] **Step 1: Add the binding**

In `TranslationServiceConfigSheet` (inside `TranslationSettingsView.swift`), add this binding next to the other private bindings (`baseURL` / `model` / `promptTemplate`):

```swift
    private var manualMode: Binding<Bool> {
        Binding(get: { draft.manualMode ?? false }, set: { draft.manualMode = $0 })
    }
```

- [ ] **Step 2: Add the toggle section**

In `TranslationServiceConfigSheet.body`, insert a new `Section` between the prompt `Section { TextEditor… }` and the conditional test-result `if testState != .idle { … }` block:

```swift
                Section {
                    Toggle(isOn: manualMode) {
                        LocalizedText(.settingsTranslationServiceManualMode)
                    }
                } footer: {
                    LocalizedText(.settingsTranslationServiceManualModeHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
```

- [ ] **Step 3: Build and manually verify**

Run: `swift build`
Expected: `Build complete!`

Run the app and verify in Settings → Translation → Add/Edit an OpenAI-compatible service:
- The "默认折叠（手动翻译）" toggle appears with its hint, defaults off.
- Toggling it on + Save persists (re-open the editor; the toggle is still on).
- With it on, that service is collapsed-by-default in the panel (this completes the Task 6 manual check).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/TranslationSettingsView.swift
git commit -m "feat(translation): add manual-mode toggle to the service editor"
```

---

### Task 8: Final verification

- [ ] **Step 1: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests pass, 0 failures (baseline was 849 + suites; this plan adds ~10 tests).

- [ ] **Step 2: Confirm a clean build**

Run: `swift build 2>&1 | tail -2`
Expected: `Build complete!`

- [ ] **Step 3: Review the commit series**

Run: `git log --oneline -8`
Expected: the per-task commits from Tasks 1–7, newest first. Confirm none were pushed (`git status` shows the branch ahead of origin).

---

## Self-Review

**Spec coverage:**
- Model `manualMode` (Optional, last field) + `startsManual` → Task 1. ✓
- `TranslationResult.Status.deferred` → Task 2. ✓
- Factory `makeStreamProvider(for:)` + exclude manual in `makeStreamProviders` → Task 3. ✓
- Coordinator `currentRequest`, `makeProvider` injection, deferred results in `translate()`, `translateOne` (build-in-guard, missing-config → `.failure` with `translationErrorMissingConfig`, sync `.loading`, runToken guard) → Task 4. ✓
- Card: seed collapsed from `startsManual`, re-collapse on `.deferred`, expand triggers `onExpandDeferred`, deferred header hint, `.deferred` body case → Task 6. ✓
- View wiring `onExpandDeferred` → Task 6. ✓
- Settings toggle bound to `manualMode` with hint footer → Task 7. ✓
- Localization (3 keys, enum + xcstrings, en + zh-Hans), reuse `translationErrorMissingConfig` → Task 5. ✓
- Tests: model Codable/legacy/startsManual; factory single + exclude; coordinator deferred + translateOne → Tasks 1–4. ✓
- Backward compat: legacy decode → nil → `startsManual` false → unchanged auto behavior — covered by `testManualModeCodableRoundTripAndLegacyDecodesNil`. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code and exact commands. ✓

**Type consistency:** `manualMode: Bool?`, `startsManual: Bool`, `TranslationResult.deferred(_:)` / `.deferred`, `makeStreamProvider(for:keychain:session:)`, `makeProvider` closure type `@MainActor (TranslationServiceConfig) -> (any TranslationProvider)?`, `translateOne(serviceID:)`, `currentRequest`, `onExpandDeferred` — names match across all tasks and the spec. ✓

**Ordering:** Localization (Task 5) precedes the UI tasks (6, 7) that reference the new keys, so each task builds cleanly on its own. ✓
