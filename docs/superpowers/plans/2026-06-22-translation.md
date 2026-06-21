# Translation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Easydict-style translation panel to AnyDoor — multiple services translate the same text concurrently into stacked cards, with auto language detection, TTS, copy, a pinnable Spotlight-style floating window, three global hotkeys (open / screenshot-translate / translate-selection), favorites+history, and a Translation settings tab.

**Architecture:** A pluggable `TranslationProvider` protocol delivers results via a unified `AsyncThrowingStream` (LLM services stream token-by-token; Google/Bing free endpoints yield once). A `@MainActor @Observable` `TranslationCoordinator` fans a request out to all enabled stream providers and publishes per-service `TranslationResult`s for the SwiftUI window; Apple's on-device Translation (macOS 15+) is rendered separately via a `.translationTask` card. Three thin `ActionProvider` builtins are the entry points (panel rows + hotkeys), reusing the existing capture/OCR pipeline and panel/hotkey infrastructure. Settings live in a UserDefaults-backed singleton (mirroring `CaptureSettings`); API keys live in a new Keychain wrapper; history is a 5th SwiftData `@Model`.

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftUI + AppKit (`NSPanel`), SwiftData, `URLSession`, NaturalLanguage (`NLLanguageRecognizer`), AVFoundation (`AVSpeechSynthesizer`), Vision (`TextRecognizer`, existing), Translation framework (macOS 15+), Security (`SecItem`). No new SPM dependencies.

**Spec:** `docs/superpowers/specs/2026-06-22-translation-design.md`

---

## File Structure

**New — Models (`Sources/AnyDoor/Models/Translation/`):**
- `TranslationLanguage.swift` — BCP-47 language value type + `catalog` + framework/service code mappings.
- `TranslationServiceKind.swift` — `apple | googleFree | bingFree | openAICompatible`.
- `TranslationServiceConfig.swift` — Codable per-service config (+ `seededDefaults()`, `defaultPromptTemplate`).
- `TranslationExchange.swift` — `TranslationRequest` / `TranslationChunk` / `TranslationResult`.
- `TranslationRecord.swift` — SwiftData `@Model` (history/favorites; the 5th model).

**New — Services (`Sources/AnyDoor/Services/Translation/`):**
- `LanguageDetector.swift`, `TranslationProvider.swift` (protocol + error), `GoogleFreeTranslationProvider.swift`, `BingFreeTranslationProvider.swift`, `OpenAICompatibleProvider.swift`, `TranslationKeychainStore.swift`, `TranslationSettings.swift`, `TranslationProviderFactory.swift`, `TranslationCoordinator.swift`, `TranslationHistoryStore.swift`, `SpeechService.swift`, `SelectedTextReader.swift`.

**New — Entry providers (`Sources/AnyDoor/Services/Providers/`):**
- `TranslateProvider.swift`, `ScreenshotTranslateProvider.swift`, `TranslateSelectionProvider.swift`.

**New — Views (`Sources/AnyDoor/Views/Translation/` + `Views/`):**
- `TranslationWindowController.swift`, `TranslationView.swift`, `TranslationServiceCard.swift`, `AppleTranslationCard.swift`, `LanguageBar.swift`, `TranslationSettingsView.swift`.

**Modified:**
- `Models/BuiltinItem.swift` — 3 cases (`.translate` / `.screenshotTranslate` / `.translateSelection`) across all switches.
- `AppDelegate.swift` — add `TranslationRecord.self` to the `ModelContainer`; register 3 providers; wire `TranslationHistoryStore.configure` + `TranslationCoordinator.shared.history`.
- `Views/SettingsView.swift` — add the Translation tab.
- `Services/SyncSettingsRegistry.swift` — whitelist the 4 portable translation keys.
- `Services/BackupService.swift` — reload `TranslationSettings` in `reconcileAfterImport()`.
- `Utilities/L10n.swift` + `Resources/Localizable.xcstrings` — new keys (en + zh-Hans).
- `CLAUDE.md` — document the subsystem and the 5th SwiftData model.

**Tests (`Tests/AnyDoorTests/`):** one test file per unit-testable component (value types, detection, the 3 adapters' request-building/parsing, keychain, settings, factory, coordinator, history, speech voice mapping, selected-text clipboard fallback, sync round-trip). AppKit/SwiftUI tasks use `swift build` + manual verification (the repo does not unit-test views).

> **Note on Apple Translation:** it is NOT a `TranslationProvider`. The coordinator fans out only Google/Bing/OpenAI. The Apple card (`AppleTranslationCard`) drives the macOS 15+ Translation framework via `.translationTask` and is hidden on macOS 14. The settings list still shows/enables/reorders an "Apple" entry; the window renders it in order alongside the generic cards.

> **Localization policy (read before any UI task):** **Task 25 is the single, canonical source for every new `L10n.Key` case + `Localizable.xcstrings` entry** (the `translation.*` UI strings, the three `builtin.translate*` titles, and `settings.tab.translation`). Because the views (Tasks 17–21, 26) are implemented before Task 25, follow this rule: **the first time any task renders a Chinese UI string, add its key (enum case + en/zh-Hans xcstrings entry) at that moment**, using the canonical key name from Task 25's list — then Task 25 becomes the completeness check (add only keys not already present; **never re-declare an existing `case`**, which fails to compile). Where an earlier task's prose names a key informally, the canonical spelling in Task 25 wins — e.g. the "识别为：%@" chip is `translationDetected` (one `%@`), "自动检测" is `translationDetectAuto`, the swap control is `translationSwapLanguages`. If a rendered string has no key in Task 25 yet, add one under the `translation.*` namespace **and append it to Task 25's list** so the consolidated set stays authoritative. `LocalizationCoverageTests` gates that every key has both `en` and `zh-Hans`.

---




### Task 1: TranslationLanguage

**Files:**
- Create: `Sources/AnyDoor/Models/Translation/TranslationLanguage.swift`
- Test: `Tests/AnyDoorTests/TranslationLanguageTests.swift`

- [ ] **Step 1: Write the failing test.** Create `Tests/AnyDoorTests/TranslationLanguageTests.swift` exercising the catalog, lookups, the `zh-Hans -> zh-CN` service mapping, and `systemDefault`.
```swift
import XCTest
@testable import AnyDoor

final class TranslationLanguageTests: XCTestCase {
    func testCatalogHasReasonableSize() {
        XCTAssertGreaterThanOrEqual(TranslationLanguage.catalog.count, 25)
    }

    func testCatalogCodesAreUnique() {
        let codes = TranslationLanguage.catalog.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "Catalog codes must be unique")
    }

    func testNamedFindsKnownLanguage() {
        XCTAssertEqual(TranslationLanguage.named("en"), TranslationLanguage.english)
        XCTAssertEqual(TranslationLanguage.named("zh-Hans"), TranslationLanguage.simplifiedChinese)
    }

    func testNamedReturnsNilForUnknown() {
        XCTAssertNil(TranslationLanguage.named("zz-Unknown"))
    }

    func testEnglishAndSimplifiedChineseConstants() {
        XCTAssertEqual(TranslationLanguage.english.code, "en")
        XCTAssertEqual(TranslationLanguage.simplifiedChinese.code, "zh-Hans")
    }

    func testIdentifiableIDIsCode() {
        XCTAssertEqual(TranslationLanguage.english.id, "en")
    }

    func testServiceCodeMapsSimplifiedChineseForGoogleAndBing() {
        let zh = TranslationLanguage.simplifiedChinese
        XCTAssertEqual(zh.serviceCode(for: .googleFree), "zh-CN")
        XCTAssertEqual(zh.serviceCode(for: .bingFree), "zh-CN")
    }

    func testServiceCodePassesThroughForApple() {
        let zh = TranslationLanguage.simplifiedChinese
        XCTAssertEqual(zh.serviceCode(for: .apple), "zh-Hans")
        XCTAssertEqual(zh.serviceCode(for: .openAICompatible), "zh-Hans")
    }

    func testServiceCodeDefaultsToCanonicalCode() {
        XCTAssertEqual(TranslationLanguage.english.serviceCode(for: .googleFree), "en")
    }

    func testNLLanguageRoundTrip() {
        XCTAssertEqual(TranslationLanguage.english.nlLanguage?.rawValue, "en")
        XCTAssertNotNil(TranslationLanguage.simplifiedChinese.nlLanguage)
    }

    func testDisplayNameFallsBackToEnglishName() {
        let invented = TranslationLanguage(code: "qa-Test", englishName: "Quux", nlLanguageRaw: nil)
        XCTAssertEqual(invented.displayName(in: Locale(identifier: "en")), "Quux")
    }

    func testSystemDefaultIsInCatalog() {
        let def = TranslationLanguage.systemDefault
        XCTAssertTrue(TranslationLanguage.catalog.contains(def))
    }
}
```

- [ ] **Step 2: Run the test (expect failure / build error).** Run `swift test --filter TranslationLanguageTests`. Expected: compile error because `TranslationLanguage` does not exist yet.

- [ ] **Step 3: Implement the type.** Create `Sources/AnyDoor/Models/Translation/TranslationLanguage.swift`.
```swift
import Foundation
import NaturalLanguage

/// A translation language identified by canonical BCP-47, with the metadata the
/// translation subsystem needs: an English fallback name, the matching
/// `NLLanguage` (for detection / TTS), and per-service code remapping.
struct TranslationLanguage: Hashable, Codable, Sendable, Identifiable {
    /// Canonical BCP-47 code, e.g. "en", "zh-Hans", "ja".
    let code: String
    /// English display name, used as a fallback when localization is unavailable.
    let englishName: String
    /// `NLLanguage` raw value, nil when no natural-language mapping applies.
    let nlLanguageRaw: String?

    var id: String { code }

    var nlLanguage: NLLanguage? { nlLanguageRaw.map { NLLanguage(rawValue: $0) } }

    /// Localized language name for the given locale, falling back to `englishName`.
    func displayName(in locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: code) ?? englishName
    }

    /// The code a given service expects. Google / Bing diverge from BCP-47 for a
    /// few languages (notably `zh-Hans` -> `zh-CN`, `zh-Hant` -> `zh-TW`).
    func serviceCode(for kind: TranslationServiceKind) -> String {
        switch kind {
        case .googleFree, .bingFree:
            return Self.serviceCodeRemap[code] ?? code
        case .apple, .openAICompatible:
            return code
        }
    }

    /// Overrides applied for Google / Bing free endpoints. Anything not listed
    /// passes through unchanged.
    private static let serviceCodeRemap: [String: String] = [
        "zh-Hans": "zh-CN",
        "zh-Hant": "zh-TW",
    ]
}

extension TranslationLanguage {
    /// ~25 common languages covering the default service surface.
    static let catalog: [TranslationLanguage] = [
        TranslationLanguage(code: "en", englishName: "English", nlLanguageRaw: NLLanguage.english.rawValue),
        TranslationLanguage(code: "zh-Hans", englishName: "Chinese (Simplified)", nlLanguageRaw: NLLanguage.simplifiedChinese.rawValue),
        TranslationLanguage(code: "zh-Hant", englishName: "Chinese (Traditional)", nlLanguageRaw: NLLanguage.traditionalChinese.rawValue),
        TranslationLanguage(code: "ja", englishName: "Japanese", nlLanguageRaw: NLLanguage.japanese.rawValue),
        TranslationLanguage(code: "ko", englishName: "Korean", nlLanguageRaw: NLLanguage.korean.rawValue),
        TranslationLanguage(code: "fr", englishName: "French", nlLanguageRaw: NLLanguage.french.rawValue),
        TranslationLanguage(code: "de", englishName: "German", nlLanguageRaw: NLLanguage.german.rawValue),
        TranslationLanguage(code: "es", englishName: "Spanish", nlLanguageRaw: NLLanguage.spanish.rawValue),
        TranslationLanguage(code: "pt", englishName: "Portuguese", nlLanguageRaw: NLLanguage.portuguese.rawValue),
        TranslationLanguage(code: "it", englishName: "Italian", nlLanguageRaw: NLLanguage.italian.rawValue),
        TranslationLanguage(code: "ru", englishName: "Russian", nlLanguageRaw: NLLanguage.russian.rawValue),
        TranslationLanguage(code: "ar", englishName: "Arabic", nlLanguageRaw: NLLanguage.arabic.rawValue),
        TranslationLanguage(code: "hi", englishName: "Hindi", nlLanguageRaw: NLLanguage.hindi.rawValue),
        TranslationLanguage(code: "th", englishName: "Thai", nlLanguageRaw: NLLanguage.thai.rawValue),
        TranslationLanguage(code: "vi", englishName: "Vietnamese", nlLanguageRaw: NLLanguage.vietnamese.rawValue),
        TranslationLanguage(code: "id", englishName: "Indonesian", nlLanguageRaw: NLLanguage.indonesian.rawValue),
        TranslationLanguage(code: "tr", englishName: "Turkish", nlLanguageRaw: NLLanguage.turkish.rawValue),
        TranslationLanguage(code: "nl", englishName: "Dutch", nlLanguageRaw: NLLanguage.dutch.rawValue),
        TranslationLanguage(code: "pl", englishName: "Polish", nlLanguageRaw: NLLanguage.polish.rawValue),
        TranslationLanguage(code: "uk", englishName: "Ukrainian", nlLanguageRaw: NLLanguage.ukrainian.rawValue),
        TranslationLanguage(code: "sv", englishName: "Swedish", nlLanguageRaw: NLLanguage.swedish.rawValue),
        TranslationLanguage(code: "cs", englishName: "Czech", nlLanguageRaw: NLLanguage.czech.rawValue),
        TranslationLanguage(code: "el", englishName: "Greek", nlLanguageRaw: NLLanguage.greek.rawValue),
        TranslationLanguage(code: "he", englishName: "Hebrew", nlLanguageRaw: NLLanguage.hebrew.rawValue),
        TranslationLanguage(code: "ro", englishName: "Romanian", nlLanguageRaw: NLLanguage.romanian.rawValue),
        TranslationLanguage(code: "da", englishName: "Danish", nlLanguageRaw: NLLanguage.danish.rawValue),
        TranslationLanguage(code: "fi", englishName: "Finnish", nlLanguageRaw: NLLanguage.finnish.rawValue),
    ]

    static func named(_ code: String) -> TranslationLanguage? {
        catalog.first { $0.code == code }
    }

    static let english = TranslationLanguage(
        code: "en",
        englishName: "English",
        nlLanguageRaw: NLLanguage.english.rawValue
    )

    static let simplifiedChinese = TranslationLanguage(
        code: "zh-Hans",
        englishName: "Chinese (Simplified)",
        nlLanguageRaw: NLLanguage.simplifiedChinese.rawValue
    )

    /// The first of `Locale.preferredLanguages` that maps into the catalog,
    /// falling back to English.
    static var systemDefault: TranslationLanguage {
        for preferred in Locale.preferredLanguages {
            let canonical = Locale(identifier: preferred)
            if let language = canonical.language.languageCode?.identifier {
                let script = canonical.language.script?.identifier
                if let script,
                   let match = named("\(language)-\(script)") {
                    return match
                }
                if let match = named(language) {
                    return match
                }
            }
            if let match = named(preferred) {
                return match
            }
        }
        return english
    }
}
```

- [ ] **Step 4: Run the test (expect pass).** Run `swift test --filter TranslationLanguageTests`. Expected: all tests pass.

- [ ] **Step 5: Commit.**
```
feat(translation): add TranslationLanguage value type and catalog
```

### Task 2: TranslationServiceKind + TranslationServiceConfig

**Files:**
- Create: `Sources/AnyDoor/Models/Translation/TranslationServiceKind.swift`
- Create: `Sources/AnyDoor/Models/Translation/TranslationServiceConfig.swift`
- Test: `Tests/AnyDoorTests/TranslationServiceConfigTests.swift`

- [ ] **Step 1: Write the failing test.** Create `Tests/AnyDoorTests/TranslationServiceConfigTests.swift` covering the kind enum, the seeded defaults, the prompt template placeholders, and Codable round-trip.
```swift
import XCTest
@testable import AnyDoor

final class TranslationServiceConfigTests: XCTestCase {
    func testServiceKindCaseCoverage() {
        XCTAssertEqual(
            Set(TranslationServiceKind.allCases),
            [.apple, .googleFree, .bingFree, .openAICompatible]
        )
    }

    func testServiceKindRawValuesAreStable() {
        XCTAssertEqual(TranslationServiceKind.apple.rawValue, "apple")
        XCTAssertEqual(TranslationServiceKind.googleFree.rawValue, "googleFree")
        XCTAssertEqual(TranslationServiceKind.bingFree.rawValue, "bingFree")
        XCTAssertEqual(TranslationServiceKind.openAICompatible.rawValue, "openAICompatible")
    }

    func testSeededDefaultsProvideAppleGoogleBing() {
        let defaults = TranslationServiceConfig.seededDefaults()
        XCTAssertEqual(defaults.map(\.kind), [.apple, .googleFree, .bingFree])
    }

    func testSeededDefaultsOrderingIsZeroBasedAndAscending() {
        let defaults = TranslationServiceConfig.seededDefaults()
        XCTAssertEqual(defaults.map(\.order), [0, 1, 2])
    }

    func testSeededDefaultsAreAllEnabledWithDistinctIDs() {
        let defaults = TranslationServiceConfig.seededDefaults()
        XCTAssertTrue(defaults.allSatisfy(\.enabled))
        XCTAssertEqual(Set(defaults.map(\.id)).count, defaults.count)
    }

    func testDefaultPromptTemplateContainsAllPlaceholders() {
        let template = TranslationServiceConfig.defaultPromptTemplate
        XCTAssertTrue(template.contains("{{source}}"))
        XCTAssertTrue(template.contains("{{target}}"))
        XCTAssertTrue(template.contains("{{text}}"))
    }

    func testCodableRoundTrip() throws {
        let config = TranslationServiceConfig(
            id: "abc",
            kind: .openAICompatible,
            displayName: "My LLM",
            iconName: "brain",
            enabled: true,
            order: 7,
            baseURL: "https://example.com/v1",
            model: "gpt-test",
            promptTemplate: TranslationServiceConfig.defaultPromptTemplate
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(TranslationServiceConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testNonLLMFieldsAreNilInSeededDefaults() {
        for config in TranslationServiceConfig.seededDefaults() {
            XCTAssertNil(config.baseURL)
            XCTAssertNil(config.model)
            XCTAssertNil(config.promptTemplate)
        }
    }
}
```

- [ ] **Step 2: Run the test (expect failure / build error).** Run `swift test --filter TranslationServiceConfigTests`. Expected: compile error because the types do not exist yet.

- [ ] **Step 3: Implement the kind enum.** Create `Sources/AnyDoor/Models/Translation/TranslationServiceKind.swift`.
```swift
import Foundation

/// The category of a translation service. Drives provider construction and the
/// per-kind code remapping in `TranslationLanguage.serviceCode(for:)`.
enum TranslationServiceKind: String, Codable, Sendable, CaseIterable {
    case apple
    case googleFree
    case bingFree
    case openAICompatible
}
```

- [ ] **Step 4: Implement the config struct.** Create `Sources/AnyDoor/Models/Translation/TranslationServiceConfig.swift`.
```swift
import Foundation

/// A configured translation service instance. The first three kinds are seeded
/// zero-config; `openAICompatible` instances are user-added and carry the LLM
/// connection fields (the API key itself lives in the Keychain, not here).
struct TranslationServiceConfig: Codable, Identifiable, Sendable, Equatable {
    var id: String
    var kind: TranslationServiceKind
    var displayName: String
    /// SF Symbol name shown on the service card.
    var iconName: String
    var enabled: Bool
    var order: Int
    /// `openAICompatible` only: base URL, e.g. "https://api.openai.com/v1".
    var baseURL: String?
    /// `openAICompatible` only: model identifier.
    var model: String?
    /// `openAICompatible` only: prompt with `{{source}}`, `{{target}}`, `{{text}}`.
    var promptTemplate: String?
}

extension TranslationServiceConfig {
    /// The built-in, zero-config services: Apple on-device, Google free, Bing free.
    static func seededDefaults() -> [TranslationServiceConfig] {
        [
            TranslationServiceConfig(
                id: TranslationServiceKind.apple.rawValue,
                kind: .apple,
                displayName: "Apple",
                iconName: "apple.logo",
                enabled: true,
                order: 0,
                baseURL: nil,
                model: nil,
                promptTemplate: nil
            ),
            TranslationServiceConfig(
                id: TranslationServiceKind.googleFree.rawValue,
                kind: .googleFree,
                displayName: "Google",
                iconName: "globe",
                enabled: true,
                order: 1,
                baseURL: nil,
                model: nil,
                promptTemplate: nil
            ),
            TranslationServiceConfig(
                id: TranslationServiceKind.bingFree.rawValue,
                kind: .bingFree,
                displayName: "Bing",
                iconName: "b.square",
                enabled: true,
                order: 2,
                baseURL: nil,
                model: nil,
                promptTemplate: nil
            ),
        ]
    }

    /// Default LLM prompt template carrying the three placeholders.
    static let defaultPromptTemplate = """
    You are a professional translation engine. Translate the text from {{source}} \
    into {{target}}. Output only the translated text, with no explanations, \
    quotes, or additional commentary.

    {{text}}
    """
}
```

- [ ] **Step 5: Run the test (expect pass).** Run `swift test --filter TranslationServiceConfigTests`. Expected: all tests pass.

- [ ] **Step 6: Commit.**
```
feat(translation): add TranslationServiceKind and TranslationServiceConfig
```

### Task 3: TranslationExchange

**Files:**
- Create: `Sources/AnyDoor/Models/Translation/TranslationExchange.swift`
- Test: `Tests/AnyDoorTests/TranslationExchangeTests.swift`

- [ ] **Step 1: Write the failing test.** Create `Tests/AnyDoorTests/TranslationExchangeTests.swift` covering `TranslationRequest` equality, the `TranslationChunk` cases, and `TranslationResult.idle()`.
```swift
import XCTest
@testable import AnyDoor

final class TranslationExchangeTests: XCTestCase {
    func testRequestEquatable() {
        let a = TranslationRequest(text: "hi", source: nil, target: .english)
        let b = TranslationRequest(text: "hi", source: nil, target: .english)
        XCTAssertEqual(a, b)

        let c = TranslationRequest(text: "hi", source: .simplifiedChinese, target: .english)
        XCTAssertNotEqual(a, c)
    }

    func testRequestNilSourceMeansAutoDetect() {
        let request = TranslationRequest(text: "hola", source: nil, target: .english)
        XCTAssertNil(request.source)
    }

    func testChunkCasesAreEquatable() {
        XCTAssertEqual(TranslationChunk.detected(.english), TranslationChunk.detected(.english))
        XCTAssertEqual(TranslationChunk.delta("a"), TranslationChunk.delta("a"))
        XCTAssertEqual(TranslationChunk.final("done"), TranslationChunk.final("done"))
        XCTAssertNotEqual(TranslationChunk.delta("a"), TranslationChunk.delta("b"))
        XCTAssertNotEqual(TranslationChunk.delta("x"), TranslationChunk.final("x"))
    }

    func testIdleFactoryProducesEmptyIdleResult() {
        let result = TranslationResult.idle("svc-1")
        XCTAssertEqual(result.serviceID, "svc-1")
        XCTAssertEqual(result.status, .idle)
        XCTAssertEqual(result.text, "")
        XCTAssertNil(result.detected)
        XCTAssertNil(result.errorMessage)
    }

    func testResultIdentifiableIDIsServiceID() {
        XCTAssertEqual(TranslationResult.idle("svc-2").id, "svc-2")
    }

    func testResultStatusCasesEquatable() {
        let statuses: [TranslationResult.Status] = [.idle, .loading, .streaming, .success, .failure]
        XCTAssertEqual(Set(statuses).count, statuses.count)
    }

    func testResultEquatable() {
        var a = TranslationResult.idle("svc")
        var b = TranslationResult.idle("svc")
        XCTAssertEqual(a, b)
        a.status = .success
        a.text = "hello"
        XCTAssertNotEqual(a, b)
        b.status = .success
        b.text = "hello"
        XCTAssertEqual(a, b)
    }
}

extension TranslationResult.Status: Hashable {}
```

- [ ] **Step 2: Run the test (expect failure / build error).** Run `swift test --filter TranslationExchangeTests`. Expected: compile error because the exchange types do not exist yet.

- [ ] **Step 3: Implement the exchange types.** Create `Sources/AnyDoor/Models/Translation/TranslationExchange.swift`.
```swift
import Foundation

/// A single translation request fanned out to every enabled provider.
struct TranslationRequest: Sendable, Equatable {
    var text: String
    /// `nil` means auto-detect the source language.
    var source: TranslationLanguage?
    var target: TranslationLanguage
}

/// One emission from a provider's stream. Non-LLM providers yield a single
/// `.final` (optionally preceded by `.detected`); LLM providers yield many
/// `.delta` chunks then `.final`.
enum TranslationChunk: Sendable, Equatable {
    case detected(TranslationLanguage)
    case delta(String)
    case final(String)
}

/// The rendered state of one service's translation, suitable as a SwiftUI card
/// model. Keyed by `serviceID` for diffable lists.
struct TranslationResult: Identifiable, Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case idle
        case loading
        case streaming
        case success
        case failure
    }

    let serviceID: String
    var status: Status
    var text: String
    var detected: TranslationLanguage?
    var errorMessage: String?

    var id: String { serviceID }

    /// An empty, idle result for the given service.
    static func idle(_ serviceID: String) -> TranslationResult {
        TranslationResult(
            serviceID: serviceID,
            status: .idle,
            text: "",
            detected: nil,
            errorMessage: nil
        )
    }
}
```

- [ ] **Step 4: Run the test (expect pass).** Run `swift test --filter TranslationExchangeTests`. Expected: all tests pass.

- [ ] **Step 5: Commit.**
```
feat(translation): add TranslationRequest, Chunk, and Result value types
```

---

## Phase 0 — Value Types (Tasks 1-3)

### Task 4: LanguageDetector

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/LanguageDetector.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/LanguageDetectorTests.swift`

- [ ] **Step 1: Write the failing test.** This test exercises Chinese / English / Japanese samples plus empty/whitespace input. It depends only on `TranslationLanguage` (from Tasks 1-3) and the new `LanguageDetector`. Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/LanguageDetectorTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class LanguageDetectorTests: XCTestCase {

    func testDetectsEnglish() {
        let detected = LanguageDetector.detect("The quick brown fox jumps over the lazy dog.")
        XCTAssertEqual(detected?.code, "en", "got: \(String(describing: detected?.code))")
    }

    func testDetectsSimplifiedChinese() {
        let detected = LanguageDetector.detect("今天天气很好，我们一起去公园散步吧。")
        // NLLanguageRecognizer reports zh-Hans for simplified script; the catalog
        // maps it to the canonical "zh-Hans" entry.
        XCTAssertEqual(detected?.code, "zh-Hans", "got: \(String(describing: detected?.code))")
    }

    func testDetectsJapanese() {
        let detected = LanguageDetector.detect("今日はとても良い天気ですね。一緒に公園へ散歩に行きましょう。")
        XCTAssertEqual(detected?.code, "ja", "got: \(String(describing: detected?.code))")
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(LanguageDetector.detect(""))
    }

    func testWhitespaceOnlyReturnsNil() {
        XCTAssertNil(LanguageDetector.detect("   \n\t  "))
    }

    func testDetectedLanguageIsInCatalog() {
        let detected = LanguageDetector.detect("Bonjour, comment allez-vous aujourd'hui ?")
        guard let detected else {
            // French may or may not be in the ~25-language catalog; if absent,
            // detect() returns nil rather than an off-catalog value. Either way
            // the contract holds: a non-nil result must be a catalog member.
            return
        }
        XCTAssertTrue(
            TranslationLanguage.catalog.contains(detected),
            "detected language must be a catalog member; got: \(detected.code)"
        )
    }
}
```

- [ ] **Step 2: Run the test, confirm it fails to compile.** Run:

```bash
swift test --filter LanguageDetectorTests
```

Expected result: build failure because `LanguageDetector` does not exist yet (`cannot find 'LanguageDetector' in scope`). This proves the test is wired to the not-yet-written type.

- [ ] **Step 3: Implement `LanguageDetector`.** Use `NLLanguageRecognizer`, then map the recognized `NLLanguage` back into the catalog. Match `TranslationLanguage.nlLanguageRaw` first (the catalog's own mapping), then fall back to the BCP-47 base code (e.g. `zh-Hans` -> `zh`) so simplified/traditional resolve to the right catalog entry. Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/LanguageDetector.swift`:

```swift
import Foundation
import NaturalLanguage

/// Detects the dominant natural language of a piece of text and maps it to a
/// `TranslationLanguage` in the app catalog. Returns `nil` for empty input or
/// when the recognizer's result has no catalog equivalent.
enum LanguageDetector {
    /// Detects the dominant language of `text`. Whitespace-only or empty input
    /// yields `nil`. A non-nil result is always a member of
    /// `TranslationLanguage.catalog`.
    static func detect(_ text: String) -> TranslationLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return nil }

        return catalogLanguage(for: language)
    }

    /// Maps an `NLLanguage` to a catalog entry. First tries an exact match on
    /// the catalog's recorded `nlLanguageRaw`; then falls back to matching the
    /// BCP-47 base code (the substring before the first "-"), which collapses
    /// region/script variants like "en-GB" onto "en".
    private static func catalogLanguage(for language: NLLanguage) -> TranslationLanguage? {
        let raw = language.rawValue

        if let exact = TranslationLanguage.catalog.first(where: { $0.nlLanguageRaw == raw }) {
            return exact
        }

        // NLLanguage rawValues are BCP-47-ish (e.g. "zh-Hans", "en", "ja").
        // Try the full raw code, then its base, against the catalog's own codes.
        if let direct = TranslationLanguage.named(raw) {
            return direct
        }

        let base = raw.split(separator: "-").first.map(String.init) ?? raw
        return TranslationLanguage.named(base)
            ?? TranslationLanguage.catalog.first { $0.code.hasPrefix(base) }
    }
}
```

- [ ] **Step 4: Run the test, confirm it passes.** Run:

```bash
swift test --filter LanguageDetectorTests
```

Expected result: all six tests pass. English resolves to `en`, the Chinese sample to `zh-Hans`, the Japanese sample to `ja`, both empty cases to `nil`, and any non-nil French result is a catalog member.

- [ ] **Step 5: Commit.**

```bash
git add Sources/AnyDoor/Services/Translation/LanguageDetector.swift Tests/AnyDoorTests/LanguageDetectorTests.swift
git commit -m "feat(translation): detect source language via NLLanguageRecognizer"
```

### Task 5: TranslationProvider protocol + TranslationProviderError

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/TranslationProvider.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/TranslationProviderTests.swift`

- [ ] **Step 1: Write the conformance test.** Task 5 has no logic of its own, so the test proves the stream contract: a fake provider conforming to `TranslationProvider` can yield a `.final` chunk through the `AsyncThrowingStream`, and a thrown error surfaces. This depends on `TranslationProvider`, `TranslationProviderError`, `TranslationChunk`, `TranslationRequest`, and `TranslationLanguage` (the exchange types come from earlier Phase-1 tasks). Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/TranslationProviderTests.swift`:

```swift
import XCTest
@testable import AnyDoor

/// A minimal provider used only to prove the `TranslationProvider` stream
/// contract: it either yields a single `.final` chunk or throws.
private struct FakeProvider: TranslationProvider {
    let id: String
    let kind: TranslationServiceKind
    let finalText: String?
    let failure: TranslationProviderError?

    init(
        id: String = "fake",
        kind: TranslationServiceKind = .googleFree,
        finalText: String? = nil,
        failure: TranslationProviderError? = nil
    ) {
        self.id = id
        self.kind = kind
        self.finalText = finalText
        self.failure = failure
    }

    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            if let finalText {
                continuation.yield(.final(finalText))
            }
            continuation.finish()
        }
    }
}

final class TranslationProviderTests: XCTestCase {

    private func makeRequest(_ text: String) -> TranslationRequest {
        TranslationRequest(text: text, source: nil, target: .english)
    }

    func testProviderYieldsFinalChunk() async throws {
        let provider = FakeProvider(finalText: "Hello")
        var chunks: [TranslationChunk] = []
        for try await chunk in provider.translate(makeRequest("你好")) {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks, [.final("Hello")])
    }

    func testProviderPropagatesError() async {
        let provider = FakeProvider(failure: .emptyInput)
        do {
            for try await _ in provider.translate(makeRequest("")) {}
            XCTFail("expected the stream to throw")
        } catch let error as TranslationProviderError {
            XCTAssertEqual(error, .emptyInput)
        } catch {
            XCTFail("expected TranslationProviderError, got: \(error)")
        }
    }

    func testProviderExposesKindAndID() {
        let provider = FakeProvider(id: "abc", kind: .bingFree, finalText: "x")
        XCTAssertEqual(provider.id, "abc")
        XCTAssertEqual(provider.kind, .bingFree)
    }

    func testErrorEquatableCases() {
        XCTAssertEqual(TranslationProviderError.badResponse(503), .badResponse(503))
        XCTAssertNotEqual(TranslationProviderError.badResponse(503), .badResponse(500))
        XCTAssertEqual(TranslationProviderError.network("offline"), .network("offline"))
        XCTAssertNotEqual(TranslationProviderError.missingAPIKey, .decodeFailed)
    }
}
```

- [ ] **Step 2: Run the test, confirm it fails to compile.** Run:

```bash
swift test --filter TranslationProviderTests
```

Expected result: build failure because `TranslationProvider` and `TranslationProviderError` do not exist yet (`cannot find type 'TranslationProvider' in scope`). This confirms the conformance test drives the not-yet-written contract.

- [ ] **Step 3: Implement the protocol, error, and a tiny stream helper.** Define `TranslationProvider`, `TranslationProviderError`, plus a small `AsyncThrowingStream` convenience for the non-streaming providers (Google/Bing yield exactly one `.final`). Keep the helper in this file per the assignment. Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/TranslationProvider.swift`:

```swift
import Foundation

/// A translation backend. Every provider exposes a single unified streaming
/// API: LLM providers emit many `.delta` chunks then a `.success`-equivalent
/// `.final`, while one-shot providers (Google/Bing/etc.) yield a single
/// `.final` chunk. `detected` source-language information arrives as a
/// `.detected` chunk when the backend reports it.
protocol TranslationProvider: Sendable {
    /// Stable identifier matching the owning `TranslationServiceConfig.id`.
    var id: String { get }
    /// The backend family this provider implements.
    var kind: TranslationServiceKind { get }
    /// Translates `request`, streaming chunks until completion. The stream
    /// finishes normally on success or finishes throwing on failure.
    func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationChunk, Error>
}

/// Errors a `TranslationProvider` can fail with. Equatable so call sites and
/// tests can assert on specific cases.
enum TranslationProviderError: Error, Sendable, Equatable {
    /// The request carried no translatable text.
    case emptyInput
    /// The backend returned a non-success HTTP status code.
    case badResponse(Int)
    /// A required API key was not configured (OpenAI-compatible only).
    case missingAPIKey
    /// The response body could not be decoded into the expected shape.
    case decodeFailed
    /// A transport-level failure; the associated value is a human-readable note.
    case network(String)
}

extension AsyncThrowingStream where Element == TranslationChunk, Failure == Error {
    /// Builds a stream that emits a single `.final` chunk and finishes. Used by
    /// one-shot (non-streaming) providers so they share the streaming contract.
    /// When `detected` is non-nil a `.detected` chunk precedes the `.final`.
    static func single(
        _ text: String,
        detected: TranslationLanguage? = nil
    ) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            if let detected {
                continuation.yield(.detected(detected))
            }
            continuation.yield(.final(text))
            continuation.finish()
        }
    }

    /// Builds a stream that immediately finishes by throwing `error`. Used by
    /// providers that fail before producing any output.
    static func failing(_ error: Error) -> AsyncThrowingStream<TranslationChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }
}
```

- [ ] **Step 4: Run the test, confirm it passes.** Run:

```bash
swift test --filter TranslationProviderTests
```

Expected result: all four tests pass — the fake provider streams a `.final("Hello")` chunk, propagates `.emptyInput`, exposes its `id`/`kind`, and the error cases compare as expected. This proves the `AsyncThrowingStream<TranslationChunk, Error>` contract that every real provider will satisfy.

- [ ] **Step 5: Commit.**

```bash
git add Sources/AnyDoor/Services/Translation/TranslationProvider.swift Tests/AnyDoorTests/TranslationProviderTests.swift
git commit -m "feat(translation): add provider protocol and streaming error contract"
```

---

## Phase 1 — Detection & Provider Protocol (Tasks 4-5)

### Task 6: GoogleFreeTranslationProvider

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/GoogleFreeTranslationProvider.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/GoogleFreeTranslationProviderTests.swift`

- [ ] **Step 1: Write the failing test for buildURL + decode.**
  Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/GoogleFreeTranslationProviderTests.swift`. The sample is a captured `translate_a/single` nested-array response (`[[["你好","hello",null,null,10]], null, "en", …]`).
  ```swift
  import XCTest
  @testable import AnyDoor

  final class GoogleFreeTranslationProviderTests: XCTestCase {
      func testBuildURLContainsClientAndQueryItems() throws {
          let url = GoogleFreeTranslationProvider.buildURL(
              text: "hello world",
              source: "auto",
              target: "zh-CN"
          )
          let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
          XCTAssertEqual(components.host, "translate.googleapis.com")
          XCTAssertEqual(components.path, "/translate_a/single")
          let items = try XCTUnwrap(components.queryItems)
          func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
          XCTAssertEqual(value("client"), "gtx")
          XCTAssertEqual(value("sl"), "auto")
          XCTAssertEqual(value("tl"), "zh-CN")
          XCTAssertEqual(value("dt"), "t")
          XCTAssertEqual(value("q"), "hello world")
      }

      func testDecodeJoinsSegmentsAndReadsDetectedCode() throws {
          // Captured shape: outer[0] = array of segments [translated, original, …];
          // outer[2] = detected source language code.
          let json = #"""
          [[["你好世界","hello world",null,null,10],["再见","goodbye",null,null,3]],null,"en",null,null,null,1.0,[],[["en"]]]
          """#
          let result = try GoogleFreeTranslationProvider.decode(Data(json.utf8))
          XCTAssertEqual(result.text, "你好世界再见")
          XCTAssertEqual(result.detectedCode, "en")
      }

      func testDecodeMissingDetectedCodeIsNil() throws {
          let json = #"""
          [[["bonjour","hi",null,null,1]],null]
          """#
          let result = try GoogleFreeTranslationProvider.decode(Data(json.utf8))
          XCTAssertEqual(result.text, "bonjour")
          XCTAssertNil(result.detectedCode)
      }

      func testDecodeMalformedThrows() {
          XCTAssertThrowsError(try GoogleFreeTranslationProvider.decode(Data("{}".utf8)))
      }
  }
  ```

- [ ] **Step 2: Run the test (expect failure).**
  `swift test --filter GoogleFreeTranslationProviderTests`
  Expected result: compile failure (type `GoogleFreeTranslationProvider` does not exist yet).

- [ ] **Step 3: Implement the provider.**
  Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/GoogleFreeTranslationProvider.swift`.
  ```swift
  import Foundation

  /// Key-free Google translate endpoint (`translate.googleapis.com/translate_a/single`,
  /// the `client=gtx` web fallback). Yields a single `.final` chunk plus a `.detected`
  /// chunk when the response reports a source language. The wire format is a nested,
  /// loosely-typed JSON array, decoded with `JSONSerialization` rather than `Codable`.
  struct GoogleFreeTranslationProvider: TranslationProvider {
      let id: String
      var kind: TranslationServiceKind { .googleFree }

      private let session: URLSession

      init(id: String, session: URLSession = .shared) {
          self.id = id
          self.session = session
      }

      func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationChunk, Error> {
          AsyncThrowingStream { continuation in
              let task = Task {
                  do {
                      let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
                      guard !trimmed.isEmpty else {
                          continuation.finish(throwing: TranslationProviderError.emptyInput)
                          return
                      }
                      let source = request.source?.serviceCode(for: .googleFree) ?? "auto"
                      let target = request.target.serviceCode(for: .googleFree)
                      let url = Self.buildURL(text: request.text, source: source, target: target)

                      let (data, response) = try await session.data(from: url)
                      guard let http = response as? HTTPURLResponse else {
                          continuation.finish(throwing: TranslationProviderError.badResponse(-1))
                          return
                      }
                      guard (200..<300).contains(http.statusCode) else {
                          continuation.finish(throwing: TranslationProviderError.badResponse(http.statusCode))
                          return
                      }

                      let decoded = try Self.decode(data)
                      if let code = decoded.detectedCode, let language = TranslationLanguage.named(code) {
                          continuation.yield(.detected(language))
                      }
                      continuation.yield(.final(decoded.text))
                      continuation.finish()
                  } catch is CancellationError {
                      continuation.finish()
                  } catch let error as TranslationProviderError {
                      continuation.finish(throwing: error)
                  } catch {
                      continuation.finish(throwing: TranslationProviderError.network(error.localizedDescription))
                  }
              }
              continuation.onTermination = { _ in task.cancel() }
          }
      }

      /// Builds the `translate_a/single` GET URL. `dt=t` requests translated text;
      /// `client=gtx` selects the unauthenticated web fallback.
      static func buildURL(text: String, source: String, target: String) -> URL {
          var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
          components.queryItems = [
              URLQueryItem(name: "client", value: "gtx"),
              URLQueryItem(name: "sl", value: source),
              URLQueryItem(name: "tl", value: target),
              URLQueryItem(name: "dt", value: "t"),
              URLQueryItem(name: "q", value: text),
          ]
          return components.url!
      }

      /// Parses the nested array: `outer[0]` is the list of `[translated, original, …]`
      /// segments (joined in order); `outer[2]` is the detected source language code.
      static func decode(_ data: Data) throws -> (text: String, detectedCode: String?) {
          let root = try JSONSerialization.jsonObject(with: data)
          guard let outer = root as? [Any], let segments = outer.first as? [Any] else {
              throw TranslationProviderError.decodeFailed
          }
          var text = ""
          for segment in segments {
              if let pair = segment as? [Any], let translated = pair.first as? String {
                  text += translated
              }
          }
          let detectedCode: String? = (outer.count > 2 ? outer[2] as? String : nil)
          return (text, detectedCode)
      }
  }
  ```

- [ ] **Step 4: Run the test (expect pass).**
  `swift test --filter GoogleFreeTranslationProviderTests`
  Expected result: all four tests pass.

- [ ] **Step 5: Build the whole target.**
  `swift build`
  Expected result: build succeeds with no errors.

- [ ] **Step 6: Commit.**
  `git add -A && git commit -m "feat(translation): add Google free stream provider"`

---

### Task 7: BingFreeTranslationProvider

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/BingFreeTranslationProvider.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/BingFreeTranslationProviderTests.swift`

- [ ] **Step 1: Write the failing test for buildTranslateRequest + decode.**
  Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/BingFreeTranslationProviderTests.swift`. The decode sample is the Microsoft Translator v3 array response shape.
  ```swift
  import XCTest
  @testable import AnyDoor

  final class BingFreeTranslationProviderTests: XCTestCase {
      func testBuildTranslateRequestURLAndQuery() throws {
          let request = BingFreeTranslationProvider.buildTranslateRequest(
              token: "JWT.TOKEN.VALUE",
              text: "hello",
              source: nil,
              target: "zh-Hans"
          )
          let url = try XCTUnwrap(request.url)
          let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
          XCTAssertEqual(components.host, "api-edge.cognitive.microsofttranslator.com")
          XCTAssertEqual(components.path, "/translate")
          let items = try XCTUnwrap(components.queryItems)
          func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
          XCTAssertEqual(value("api-version"), "3.0")
          XCTAssertEqual(value("to"), "zh-Hans")
          // No explicit source -> auto-detect, no `from` query item.
          XCTAssertNil(value("from"))
      }

      func testBuildTranslateRequestHeadersAndBody() throws {
          let request = BingFreeTranslationProvider.buildTranslateRequest(
              token: "JWT.TOKEN.VALUE",
              text: "hello",
              source: "en",
              target: "zh-Hans"
          )
          XCTAssertEqual(request.httpMethod, "POST")
          XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer JWT.TOKEN.VALUE")
          XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
          let url = try XCTUnwrap(request.url)
          let from = URLComponents(url: url, resolvingAgainstBaseURL: false)?
              .queryItems?.first { $0.name == "from" }?.value
          XCTAssertEqual(from, "en")

          // Body must be a JSON array of `{ "Text": "..." }` objects.
          let body = try XCTUnwrap(request.httpBody)
          let decoded = try JSONSerialization.jsonObject(with: body) as? [[String: String]]
          XCTAssertEqual(decoded?.first?["Text"], "hello")
      }

      func testDecodeReadsTextAndDetectedLanguage() throws {
          // Captured Microsoft Translator v3 shape.
          let json = #"""
          [{"detectedLanguage":{"language":"en","score":1.0},"translations":[{"text":"你好","to":"zh-Hans"}]}]
          """#
          let result = try BingFreeTranslationProvider.decode(Data(json.utf8))
          XCTAssertEqual(result.text, "你好")
          XCTAssertEqual(result.detectedCode, "en")
      }

      func testDecodeWithoutDetectedLanguageIsNil() throws {
          let json = #"""
          [{"translations":[{"text":"hola","to":"es"}]}]
          """#
          let result = try BingFreeTranslationProvider.decode(Data(json.utf8))
          XCTAssertEqual(result.text, "hola")
          XCTAssertNil(result.detectedCode)
      }

      func testDecodeEmptyArrayThrows() {
          XCTAssertThrowsError(try BingFreeTranslationProvider.decode(Data("[]".utf8)))
      }
  }
  ```

- [ ] **Step 2: Run the test (expect failure).**
  `swift test --filter BingFreeTranslationProviderTests`
  Expected result: compile failure (type `BingFreeTranslationProvider` does not exist yet).

- [ ] **Step 3: Implement the provider.**
  Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/BingFreeTranslationProvider.swift`.
  ```swift
  import Foundation

  /// Key-free Microsoft/Bing translate path. First fetches a short-lived JWT from
  /// `edge.microsoft.com/translate/auth`, then POSTs to the edge Translator v3
  /// endpoint. Yields a `.detected` chunk (when reported) plus one `.final` chunk.
  struct BingFreeTranslationProvider: TranslationProvider {
      let id: String
      var kind: TranslationServiceKind { .bingFree }

      private let session: URLSession

      init(id: String, session: URLSession = .shared) {
          self.id = id
          self.session = session
      }

      func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationChunk, Error> {
          AsyncThrowingStream { continuation in
              let task = Task {
                  do {
                      let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
                      guard !trimmed.isEmpty else {
                          continuation.finish(throwing: TranslationProviderError.emptyInput)
                          return
                      }
                      let token = try await Self.fetchAuthToken(session: session)
                      let source = request.source?.serviceCode(for: .bingFree)
                      let target = request.target.serviceCode(for: .bingFree)
                      let urlRequest = Self.buildTranslateRequest(
                          token: token,
                          text: request.text,
                          source: source,
                          target: target
                      )

                      let (data, response) = try await session.data(for: urlRequest)
                      guard let http = response as? HTTPURLResponse else {
                          continuation.finish(throwing: TranslationProviderError.badResponse(-1))
                          return
                      }
                      guard (200..<300).contains(http.statusCode) else {
                          continuation.finish(throwing: TranslationProviderError.badResponse(http.statusCode))
                          return
                      }

                      let decoded = try Self.decode(data)
                      if let code = decoded.detectedCode, let language = TranslationLanguage.named(code) {
                          continuation.yield(.detected(language))
                      }
                      continuation.yield(.final(decoded.text))
                      continuation.finish()
                  } catch is CancellationError {
                      continuation.finish()
                  } catch let error as TranslationProviderError {
                      continuation.finish(throwing: error)
                  } catch {
                      continuation.finish(throwing: TranslationProviderError.network(error.localizedDescription))
                  }
              }
              continuation.onTermination = { _ in task.cancel() }
          }
      }

      /// GETs a bearer JWT used to authorize the translate call. The endpoint returns
      /// the raw token string as its body.
      static func fetchAuthToken(session: URLSession) async throws -> String {
          let url = URL(string: "https://edge.microsoft.com/translate/auth")!
          let (data, response) = try await session.data(from: url)
          guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
              throw TranslationProviderError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
          }
          let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
          guard !token.isEmpty else { throw TranslationProviderError.decodeFailed }
          return token
      }

      /// Builds the v3 `translate` POST. `source == nil` requests auto-detection by
      /// omitting the `from` query item. The body is a JSON array of `{ "Text": … }`.
      static func buildTranslateRequest(token: String, text: String, source: String?, target: String) -> URLRequest {
          var components = URLComponents(string: "https://api-edge.cognitive.microsofttranslator.com/translate")!
          var queryItems = [
              URLQueryItem(name: "api-version", value: "3.0"),
              URLQueryItem(name: "to", value: target),
          ]
          if let source { queryItems.append(URLQueryItem(name: "from", value: source)) }
          components.queryItems = queryItems

          var request = URLRequest(url: components.url!)
          request.httpMethod = "POST"
          request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          let body = [["Text": text]]
          request.httpBody = try? JSONSerialization.data(withJSONObject: body)
          return request
      }

      /// Parses the v3 response array: `[0].translations[0].text` is the result;
      /// `[0].detectedLanguage.language` (optional) is the detected source code.
      static func decode(_ data: Data) throws -> (text: String, detectedCode: String?) {
          let root = try JSONSerialization.jsonObject(with: data)
          guard let array = root as? [Any], let first = array.first as? [String: Any] else {
              throw TranslationProviderError.decodeFailed
          }
          guard
              let translations = first["translations"] as? [Any],
              let translation = translations.first as? [String: Any],
              let text = translation["text"] as? String
          else {
              throw TranslationProviderError.decodeFailed
          }
          let detectedCode = (first["detectedLanguage"] as? [String: Any])?["language"] as? String
          return (text, detectedCode)
      }
  }
  ```

- [ ] **Step 4: Run the test (expect pass).**
  `swift test --filter BingFreeTranslationProviderTests`
  Expected result: all five tests pass.

- [ ] **Step 5: Build the whole target.**
  `swift build`
  Expected result: build succeeds with no errors.

- [ ] **Step 6: Commit.**
  `git add -A && git commit -m "feat(translation): add Bing free stream provider"`

---

### Task 8: OpenAICompatibleProvider

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/OpenAICompatibleProvider.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/OpenAICompatibleProviderTests.swift`

- [ ] **Step 1: Write the failing test for renderPrompt + buildRequest + parseSSELine.**
  Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/OpenAICompatibleProviderTests.swift`.
  ```swift
  import XCTest
  @testable import AnyDoor

  final class OpenAICompatibleProviderTests: XCTestCase {
      func testRenderPromptSubstitutesAllPlaceholders() {
          let template = "Translate from {{source}} to {{target}}:\n{{text}}"
          let rendered = OpenAICompatibleProvider.renderPrompt(
              template: template,
              source: .english,
              target: .simplifiedChinese,
              text: "hello"
          )
          XCTAssertEqual(rendered, "Translate from English to Chinese (Simplified):\nhello")
      }

      func testRenderPromptAutoSourceUsesAutoLabel() {
          let template = "{{source}}->{{target}}: {{text}}"
          let rendered = OpenAICompatibleProvider.renderPrompt(
              template: template,
              source: nil,
              target: .english,
              text: "你好"
          )
          // A nil source renders the literal "auto" so the model auto-detects.
          XCTAssertEqual(rendered, "auto->English: 你好")
      }

      func testBuildRequestHeadersAndBody() throws {
          let request = try OpenAICompatibleProvider.buildRequest(
              baseURL: "https://api.example.com/v1",
              model: "gpt-4o-mini",
              apiKey: "sk-test-123",
              prompt: "translate this"
          )
          let url = try XCTUnwrap(request.url)
          XCTAssertEqual(url.absoluteString, "https://api.example.com/v1/chat/completions")
          XCTAssertEqual(request.httpMethod, "POST")
          XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-123")
          XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

          let body = try XCTUnwrap(request.httpBody)
          let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
          XCTAssertEqual(json["model"] as? String, "gpt-4o-mini")
          XCTAssertEqual(json["stream"] as? Bool, true)
          let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
          XCTAssertEqual(messages.first?["role"] as? String, "user")
          XCTAssertEqual(messages.first?["content"] as? String, "translate this")
      }

      func testBuildRequestTrimsTrailingSlashOnBaseURL() throws {
          let request = try OpenAICompatibleProvider.buildRequest(
              baseURL: "https://api.example.com/v1/",
              model: "m",
              apiKey: "k",
              prompt: "p"
          )
          XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/chat/completions")
      }

      func testBuildRequestRejectsInvalidBaseURL() {
          XCTAssertThrowsError(
              try OpenAICompatibleProvider.buildRequest(baseURL: "", model: "m", apiKey: "k", prompt: "p")
          )
      }

      func testParseSSELineExtractsDeltaContent() {
          let line = #"data: {"choices":[{"delta":{"content":"你好"}}]}"#
          XCTAssertEqual(OpenAICompatibleProvider.parseSSELine(line), "你好")
      }

      func testParseSSELineDoneReturnsNil() {
          XCTAssertNil(OpenAICompatibleProvider.parseSSELine("data: [DONE]"))
      }

      func testParseSSELineNonContentReturnsNil() {
          // Role-only opening delta carries no content.
          let line = #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#
          XCTAssertNil(OpenAICompatibleProvider.parseSSELine(line))
      }

      func testParseSSELineNonDataLineReturnsNil() {
          XCTAssertNil(OpenAICompatibleProvider.parseSSELine(""))
          XCTAssertNil(OpenAICompatibleProvider.parseSSELine(": keep-alive"))
      }
  }
  ```

- [ ] **Step 2: Run the test (expect failure).**
  `swift test --filter OpenAICompatibleProviderTests`
  Expected result: compile failure (type `OpenAICompatibleProvider` does not exist yet).

- [ ] **Step 3: Implement the provider.**
  Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/OpenAICompatibleProvider.swift`.
  ```swift
  import Foundation

  /// Translates via an OpenAI-compatible `/chat/completions` endpoint with SSE
  /// streaming. The configured prompt template (placeholders `{{source}}`
  /// `{{target}}` `{{text}}`) becomes a single user message; each `delta.content`
  /// chunk is yielded as `.delta`, and the accumulated text is yielded as `.final`.
  struct OpenAICompatibleProvider: TranslationProvider {
      let id: String
      var kind: TranslationServiceKind { .openAICompatible }

      private let config: TranslationServiceConfig
      private let apiKey: String
      private let session: URLSession

      init(config: TranslationServiceConfig, apiKey: String, session: URLSession = .shared) {
          self.id = config.id
          self.config = config
          self.apiKey = apiKey
          self.session = session
      }

      func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationChunk, Error> {
          AsyncThrowingStream { continuation in
              let task = Task {
                  do {
                      let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
                      guard !trimmed.isEmpty else {
                          continuation.finish(throwing: TranslationProviderError.emptyInput)
                          return
                      }
                      guard !apiKey.isEmpty else {
                          continuation.finish(throwing: TranslationProviderError.missingAPIKey)
                          return
                      }
                      guard let baseURL = config.baseURL, let model = config.model else {
                          continuation.finish(throwing: TranslationProviderError.decodeFailed)
                          return
                      }

                      let template = config.promptTemplate ?? TranslationServiceConfig.defaultPromptTemplate
                      let prompt = Self.renderPrompt(
                          template: template,
                          source: request.source,
                          target: request.target,
                          text: request.text
                      )
                      let urlRequest = try Self.buildRequest(
                          baseURL: baseURL,
                          model: model,
                          apiKey: apiKey,
                          prompt: prompt
                      )

                      let (bytes, response) = try await session.bytes(for: urlRequest)
                      guard let http = response as? HTTPURLResponse else {
                          continuation.finish(throwing: TranslationProviderError.badResponse(-1))
                          return
                      }
                      guard (200..<300).contains(http.statusCode) else {
                          continuation.finish(throwing: TranslationProviderError.badResponse(http.statusCode))
                          return
                      }

                      var accumulated = ""
                      for try await line in bytes.lines {
                          try Task.checkCancellation()
                          if let delta = Self.parseSSELine(line), !delta.isEmpty {
                              accumulated += delta
                              continuation.yield(.delta(delta))
                          }
                      }
                      continuation.yield(.final(accumulated))
                      continuation.finish()
                  } catch is CancellationError {
                      continuation.finish()
                  } catch let error as TranslationProviderError {
                      continuation.finish(throwing: error)
                  } catch {
                      continuation.finish(throwing: TranslationProviderError.network(error.localizedDescription))
                  }
              }
              continuation.onTermination = { _ in task.cancel() }
          }
      }

      /// Substitutes the three template placeholders. A nil source renders the literal
      /// "auto" so the model performs detection.
      static func renderPrompt(
          template: String,
          source: TranslationLanguage?,
          target: TranslationLanguage,
          text: String
      ) -> String {
          let sourceName = source?.englishName ?? "auto"
          return template
              .replacingOccurrences(of: "{{source}}", with: sourceName)
              .replacingOccurrences(of: "{{target}}", with: target.englishName)
              .replacingOccurrences(of: "{{text}}", with: text)
      }

      /// Builds the streaming `POST {baseURL}/chat/completions` request. A trailing
      /// slash on `baseURL` is trimmed so the path joins cleanly.
      static func buildRequest(baseURL: String, model: String, apiKey: String, prompt: String) throws -> URLRequest {
          let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
          let normalizedBase = trimmedBase.hasSuffix("/") ? String(trimmedBase.dropLast()) : trimmedBase
          guard !normalizedBase.isEmpty, let url = URL(string: normalizedBase + "/chat/completions") else {
              throw TranslationProviderError.network("invalid base URL")
          }

          var request = URLRequest(url: url)
          request.httpMethod = "POST"
          request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          let body: [String: Any] = [
              "model": model,
              "stream": true,
              "messages": [["role": "user", "content": prompt]],
          ]
          request.httpBody = try JSONSerialization.data(withJSONObject: body)
          return request
      }

      /// Extracts `choices[0].delta.content` from one SSE line. Returns nil for
      /// non-`data:` lines, the `[DONE]` sentinel, and content-less deltas.
      static func parseSSELine(_ line: String) -> String? {
          let trimmed = line.trimmingCharacters(in: .whitespaces)
          guard trimmed.hasPrefix("data:") else { return nil }
          let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
          guard payload != "[DONE]", !payload.isEmpty else { return nil }
          guard
              let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [Any],
              let choice = choices.first as? [String: Any],
              let delta = choice["delta"] as? [String: Any],
              let content = delta["content"] as? String
          else {
              return nil
          }
          return content
      }
  }
  ```

- [ ] **Step 4: Run the test (expect pass).**
  `swift test --filter OpenAICompatibleProviderTests`
  Expected result: all nine tests pass. (Note: `testRenderPromptSubstitutesAllPlaceholders` and `testRenderPromptAutoSourceUsesAutoLabel` assert the `englishName` values from `TranslationLanguage.catalog` — if `english.englishName`/`simplifiedChinese.englishName` differ from "English"/"Chinese (Simplified)" in Task 1's catalog, adjust the expected strings to match the catalog.)

- [ ] **Step 5: Build the whole target.**
  `swift build`
  Expected result: build succeeds with no errors.

- [ ] **Step 6: Commit.**
  `git add -A && git commit -m "feat(translation): add OpenAI-compatible streaming provider"`

---

## Phase 2 — Stream Adapters: Google, Bing, OpenAI-compatible (Tasks 6-8)

### Task 9: TranslationKeychainStore

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/TranslationKeychainStore.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/TranslationKeychainStoreTests.swift`

- [ ] **Step 1: Write the failing test.** Create `TranslationKeychainStoreTests.swift` with a unique throwaway service name per test so the real app keychain is never touched, and clean up in `tearDown`.

```swift
import XCTest
@testable import AnyDoor

final class TranslationKeychainStoreTests: XCTestCase {
    private var serviceName = ""

    override func setUp() {
        super.setUp()
        // Unique throwaway service so we never collide with the real app keychain.
        serviceName = "dev.bybee.AnyDoor.translation.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        // Best-effort cleanup of anything a test left behind.
        let store = TranslationKeychainStore(service: serviceName)
        for id in ["a", "b", "missing", "roundtrip"] {
            store.deleteAPIKey(for: id)
        }
        super.tearDown()
    }

    func testReadMissingKeyReturnsNil() {
        let store = TranslationKeychainStore(service: serviceName)
        XCTAssertNil(store.apiKey(for: "missing"))
    }

    func testRoundTrip() {
        let store = TranslationKeychainStore(service: serviceName)
        store.setAPIKey("sk-secret-123", for: "roundtrip")
        XCTAssertEqual(store.apiKey(for: "roundtrip"), "sk-secret-123")
    }

    func testSetOverwritesExistingValue() {
        let store = TranslationKeychainStore(service: serviceName)
        store.setAPIKey("first", for: "a")
        store.setAPIKey("second", for: "a")
        XCTAssertEqual(store.apiKey(for: "a"), "second")
    }

    func testDeleteRemovesValue() {
        let store = TranslationKeychainStore(service: serviceName)
        store.setAPIKey("to-delete", for: "b")
        XCTAssertEqual(store.apiKey(for: "b"), "to-delete")
        store.deleteAPIKey(for: "b")
        XCTAssertNil(store.apiKey(for: "b"))
    }

    func testKeysAreScopedByAccount() {
        let store = TranslationKeychainStore(service: serviceName)
        store.setAPIKey("alpha", for: "a")
        store.setAPIKey("beta", for: "b")
        XCTAssertEqual(store.apiKey(for: "a"), "alpha")
        XCTAssertEqual(store.apiKey(for: "b"), "beta")
    }

    func testServiceIsolation() {
        let storeA = TranslationKeychainStore(service: serviceName)
        let storeB = TranslationKeychainStore(service: serviceName + ".other")
        storeA.setAPIKey("only-in-a", for: "a")
        XCTAssertNil(storeB.apiKey(for: "a"))
        storeB.deleteAPIKey(for: "a") // nothing to clean, but keep symmetric
    }
}
```

- [ ] **Step 2: Run the test (expect failure).** Run `swift test --filter TranslationKeychainStoreTests`. Expected: compile failure / "cannot find 'TranslationKeychainStore' in scope" because the type does not exist yet.

- [ ] **Step 3: Implement `TranslationKeychainStore`.** Create the file with a `SecItem`-backed generic-password wrapper. `setAPIKey` deletes then adds (upsert), `apiKey` copies the data back, `deleteAPIKey` removes the item.

```swift
import Foundation
import Security

/// Thin Keychain wrapper for per-instance LLM API keys. Each secret is stored as
/// a `kSecClassGenericPassword` item keyed by `account = id` under the injected
/// `service` string. Secrets live ONLY here and are excluded from backup/sync.
struct TranslationKeychainStore {
    private let service: String

    init(service: String = "dev.bybee.AnyDoor.translation") {
        self.service = service
    }

    /// Upsert: delete any existing item for `id`, then add the new value.
    /// A no-op (empty) value is treated as a delete so we never persist "".
    func setAPIKey(_ key: String, for id: String) {
        deleteAPIKey(for: id)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func apiKey(for id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    func deleteAPIKey(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 4: Run the test (expect pass).** Run `swift test --filter TranslationKeychainStoreTests`. Expected: all tests pass.

- [ ] **Step 5: Commit.** `git add` the two files and commit with:
  ```
  feat(translation): add Keychain store for LLM API keys
  ```

### Task 10: TranslationSettings

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/TranslationSettings.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/TranslationSettingsTests.swift`

> Depends on `TranslationServiceKind`, `TranslationServiceConfig` (+ `seededDefaults()`), `TranslationLanguage` (`named`, `english`, `systemDefault`) from earlier phases — they must already compile.

- [ ] **Step 1: Write the failing test.** Create `TranslationSettingsTests.swift` mirroring `CaptureSettingsTests` (isolated UserDefaults suite, `@MainActor` class). Cover: defaults when unset, services seeded on empty/garbage JSON, setter persistence, services JSON round-trip + order sort, upsert/remove, computed languages, `enabledServicesInOrder`, and `reloadFromDefaults`.

```swift
import XCTest
@testable import AnyDoor

@MainActor
final class TranslationSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "translation.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testDefaultsWhenUnset() {
        let s = TranslationSettings(defaults: makeDefaults())
        XCTAssertEqual(s.targetLanguageCode, TranslationLanguage.systemDefault.code)
        XCTAssertEqual(s.secondTargetLanguageCode, TranslationLanguage.english.code)
        XCTAssertFalse(s.autoSpeak)
        XCTAssertEqual(s.services.map(\.kind), TranslationServiceConfig.seededDefaults().map(\.kind))
    }

    func testGarbageServicesJSONFallsBackToSeeded() {
        let d = makeDefaults()
        d.set("not-json", forKey: TranslationSettings.servicesKey)
        let s = TranslationSettings(defaults: d)
        XCTAssertEqual(s.services.map(\.id), TranslationServiceConfig.seededDefaults().map(\.id))
    }

    func testEmptyServicesArrayFallsBackToSeeded() {
        let d = makeDefaults()
        let empty = try! JSONEncoder().encode([TranslationServiceConfig]())
        d.set(empty, forKey: TranslationSettings.servicesKey)
        let s = TranslationSettings(defaults: d)
        XCTAssertEqual(s.services.map(\.id), TranslationServiceConfig.seededDefaults().map(\.id))
    }

    func testScalarSettersPersist() {
        let d = makeDefaults()
        let s = TranslationSettings(defaults: d)
        s.setTargetLanguageCode("ja")
        s.setSecondTargetLanguageCode("fr")
        s.setAutoSpeak(true)
        let reloaded = TranslationSettings(defaults: d)
        XCTAssertEqual(reloaded.targetLanguageCode, "ja")
        XCTAssertEqual(reloaded.secondTargetLanguageCode, "fr")
        XCTAssertTrue(reloaded.autoSpeak)
    }

    func testSetServicesSortsByOrderAndPersists() {
        let d = makeDefaults()
        let s = TranslationSettings(defaults: d)
        var a = TranslationServiceConfig.seededDefaults()[0]; a.id = "a"; a.order = 5
        var b = TranslationServiceConfig.seededDefaults()[1]; b.id = "b"; b.order = 1
        s.setServices([a, b])
        XCTAssertEqual(s.services.map(\.id), ["b", "a"])
        let reloaded = TranslationSettings(defaults: d)
        XCTAssertEqual(reloaded.services.map(\.id), ["b", "a"])
    }

    func testUpsertReplacesByID() {
        let s = TranslationSettings(defaults: makeDefaults())
        let seeded = s.services
        var changed = seeded[0]
        changed.displayName = "Renamed"
        s.upsertService(changed)
        XCTAssertEqual(s.services.count, seeded.count)
        XCTAssertEqual(s.services.first(where: { $0.id == changed.id })?.displayName, "Renamed")
    }

    func testUpsertAppendsNewID() {
        let s = TranslationSettings(defaults: makeDefaults())
        let count = s.services.count
        var added = TranslationServiceConfig.seededDefaults()[0]
        added.id = "brand-new"; added.order = 99
        s.upsertService(added)
        XCTAssertEqual(s.services.count, count + 1)
        XCTAssertTrue(s.services.contains(where: { $0.id == "brand-new" }))
    }

    func testRemoveService() {
        let s = TranslationSettings(defaults: makeDefaults())
        let target = s.services[0].id
        s.removeService(id: target)
        XCTAssertFalse(s.services.contains(where: { $0.id == target }))
    }

    func testComputedLanguages() {
        let d = makeDefaults()
        let s = TranslationSettings(defaults: d)
        s.setTargetLanguageCode("ja")
        s.setSecondTargetLanguageCode("en")
        XCTAssertEqual(s.targetLanguage.code, "ja")
        XCTAssertEqual(s.secondTargetLanguage.code, "en")
        // Unknown codes fall back.
        s.setTargetLanguageCode("zzz")
        s.setSecondTargetLanguageCode("zzz")
        XCTAssertEqual(s.targetLanguage.code, TranslationLanguage.systemDefault.code)
        XCTAssertEqual(s.secondTargetLanguage.code, TranslationLanguage.english.code)
    }

    func testEnabledServicesInOrderFiltersAndSorts() {
        let s = TranslationSettings(defaults: makeDefaults())
        var first = TranslationServiceConfig.seededDefaults()[0]
        first.id = "x"; first.enabled = true; first.order = 2
        var second = TranslationServiceConfig.seededDefaults()[1]
        second.id = "y"; second.enabled = false; second.order = 0
        var third = TranslationServiceConfig.seededDefaults()[2]
        third.id = "z"; third.enabled = true; third.order = 1
        s.setServices([first, second, third])
        XCTAssertEqual(s.enabledServicesInOrder.map(\.id), ["z", "x"])
    }

    func testReloadFromDefaultsReReads() {
        let d = makeDefaults()
        let s = TranslationSettings(defaults: d)
        // Mutate the backing store behind the instance's back.
        d.set("ko", forKey: TranslationSettings.targetLanguageKey)
        d.set(true, forKey: TranslationSettings.autoSpeakKey)
        s.reloadFromDefaults()
        XCTAssertEqual(s.targetLanguageCode, "ko")
        XCTAssertTrue(s.autoSpeak)
    }
}
```

- [ ] **Step 2: Run the test (expect failure).** Run `swift test --filter TranslationSettingsTests`. Expected: compile failure — `TranslationSettings` does not exist yet.

- [ ] **Step 3: Implement `TranslationSettings`.** Create the file mirroring `CaptureSettings` exactly (UserDefaults-backed, `private(set)` vars, write-through setters, `init(defaults:)`, `reloadFromDefaults`). Add a shared services-decode helper that falls back to `seededDefaults()` on empty/garbage JSON, and a services-encode-and-sort helper.

```swift
import Foundation

/// UserDefaults-backed translation configuration. Mirrors `CaptureSettings`:
/// explicit write-through setters, `@MainActor @Observable` so SwiftUI settings
/// can bind. Services are stored as JSON-encoded `[TranslationServiceConfig]`,
/// falling back to `seededDefaults()` when the stored value is empty or garbage.
@MainActor
@Observable
final class TranslationSettings {
    static let shared = TranslationSettings()

    static let targetLanguageKey = "translation.targetLanguage"
    static let secondTargetLanguageKey = "translation.secondTargetLanguage"
    static let autoSpeakKey = "translation.autoSpeak"
    static let servicesKey = "translation.services"

    private let defaults: UserDefaults

    private(set) var targetLanguageCode: String
    private(set) var secondTargetLanguageCode: String
    private(set) var autoSpeak: Bool
    private(set) var services: [TranslationServiceConfig]

    private static func readServices(_ defaults: UserDefaults) -> [TranslationServiceConfig] {
        guard let data = defaults.data(forKey: servicesKey),
              let decoded = try? JSONDecoder().decode([TranslationServiceConfig].self, from: data),
              !decoded.isEmpty else {
            return TranslationServiceConfig.seededDefaults()
        }
        return decoded.sorted { $0.order < $1.order }
    }

    private func writeServices(_ value: [TranslationServiceConfig]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.servicesKey)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.targetLanguageCode = defaults.string(forKey: Self.targetLanguageKey)
            ?? TranslationLanguage.systemDefault.code
        self.secondTargetLanguageCode = defaults.string(forKey: Self.secondTargetLanguageKey)
            ?? TranslationLanguage.english.code
        self.autoSpeak = defaults.object(forKey: Self.autoSpeakKey) as? Bool ?? false
        self.services = Self.readServices(defaults)
    }

    func setTargetLanguageCode(_ value: String) {
        targetLanguageCode = value
        defaults.set(value, forKey: Self.targetLanguageKey)
    }

    func setSecondTargetLanguageCode(_ value: String) {
        secondTargetLanguageCode = value
        defaults.set(value, forKey: Self.secondTargetLanguageKey)
    }

    func setAutoSpeak(_ value: Bool) {
        autoSpeak = value
        defaults.set(value, forKey: Self.autoSpeakKey)
    }

    func setServices(_ value: [TranslationServiceConfig]) {
        let sorted = value.sorted { $0.order < $1.order }
        services = sorted
        writeServices(sorted)
    }

    func upsertService(_ config: TranslationServiceConfig) {
        var next = services
        if let index = next.firstIndex(where: { $0.id == config.id }) {
            next[index] = config
        } else {
            next.append(config)
        }
        setServices(next)
    }

    func removeService(id: String) {
        setServices(services.filter { $0.id != id })
    }

    /// Re-read after a config import (parallels `CaptureSettings.reloadFromDefaults`).
    func reloadFromDefaults() {
        targetLanguageCode = defaults.string(forKey: Self.targetLanguageKey)
            ?? TranslationLanguage.systemDefault.code
        secondTargetLanguageCode = defaults.string(forKey: Self.secondTargetLanguageKey)
            ?? TranslationLanguage.english.code
        autoSpeak = defaults.object(forKey: Self.autoSpeakKey) as? Bool ?? false
        services = Self.readServices(defaults)
    }

    var targetLanguage: TranslationLanguage {
        TranslationLanguage.named(targetLanguageCode) ?? TranslationLanguage.systemDefault
    }

    var secondTargetLanguage: TranslationLanguage {
        TranslationLanguage.named(secondTargetLanguageCode) ?? TranslationLanguage.english
    }

    var enabledServicesInOrder: [TranslationServiceConfig] {
        services.filter(\.enabled).sorted { $0.order < $1.order }
    }
}
```

- [ ] **Step 4: Run the test (expect pass).** Run `swift test --filter TranslationSettingsTests`. Expected: all tests pass.

- [ ] **Step 5: Commit.** `git add` the two files and commit with:
  ```
  feat(translation): add UserDefaults-backed TranslationSettings
  ```

### Task 11: TranslationProviderFactory

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/TranslationProviderFactory.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/TranslationProviderFactoryTests.swift`

> Depends on `TranslationSettings`, `TranslationKeychainStore`, and the three stream providers (`GoogleFreeTranslationProvider`, `BingFreeTranslationProvider`, `OpenAICompatibleProvider`) from earlier phases — they must already compile.

- [ ] **Step 1: Write the failing test.** Create `TranslationProviderFactoryTests.swift`. Use an isolated UserDefaults suite plus a throwaway keychain service name; seed services with `apple` (must be skipped — it is not a stream provider), `googleFree`, `bingFree`, and two `openAICompatible` instances (one with a key in the keychain, one without — the keyless one must be skipped). Assert the produced provider kinds and order, and that each provider's `id` matches its config.

```swift
import XCTest
@testable import AnyDoor

@MainActor
final class TranslationProviderFactoryTests: XCTestCase {
    private var defaultsSuite = ""
    private var keychainService = ""

    override func setUp() {
        super.setUp()
        defaultsSuite = "translation.factory.tests.\(UUID().uuidString)"
        keychainService = "dev.bybee.AnyDoor.translation.factory.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.deleteAPIKey(for: "llm-keyed")
        keychain.deleteAPIKey(for: "llm-keyless")
        super.tearDown()
    }

    private func makeConfig(id: String,
                            kind: TranslationServiceKind,
                            order: Int,
                            enabled: Bool = true,
                            baseURL: String? = nil,
                            model: String? = nil) -> TranslationServiceConfig {
        TranslationServiceConfig(
            id: id,
            kind: kind,
            displayName: id,
            iconName: "globe",
            enabled: enabled,
            order: order,
            baseURL: baseURL,
            model: model,
            promptTemplate: TranslationServiceConfig.defaultPromptTemplate
        )
    }

    private func makeSettings(_ configs: [TranslationServiceConfig]) -> TranslationSettings {
        let d = UserDefaults(suiteName: defaultsSuite)!
        let s = TranslationSettings(defaults: d)
        s.setServices(configs)
        return s
    }

    func testBuildsNonAppleStreamProvidersInOrder() {
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.setAPIKey("sk-123", for: "llm-keyed")
        let settings = makeSettings([
            makeConfig(id: "apple", kind: .apple, order: 0),
            makeConfig(id: "google", kind: .googleFree, order: 1),
            makeConfig(id: "bing", kind: .bingFree, order: 2),
            makeConfig(id: "llm-keyed", kind: .openAICompatible, order: 3,
                       baseURL: "https://api.example.com/v1", model: "gpt-x"),
        ])
        let providers = TranslationProviderFactory.makeStreamProviders(
            settings: settings, keychain: keychain)
        XCTAssertEqual(providers.map(\.kind), [.googleFree, .bingFree, .openAICompatible])
        XCTAssertEqual(providers.map(\.id), ["google", "bing", "llm-keyed"])
    }

    func testSkipsAppleAndDisabledServices() {
        let settings = makeSettings([
            makeConfig(id: "apple", kind: .apple, order: 0),
            makeConfig(id: "google", kind: .googleFree, order: 1, enabled: false),
            makeConfig(id: "bing", kind: .bingFree, order: 2),
        ])
        let providers = TranslationProviderFactory.makeStreamProviders(
            settings: settings, keychain: TranslationKeychainStore(service: keychainService))
        XCTAssertEqual(providers.map(\.id), ["bing"])
    }

    func testSkipsOpenAIWithoutKeychainKey() {
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.setAPIKey("sk-123", for: "llm-keyed")
        // "llm-keyless" intentionally has NO key stored.
        let settings = makeSettings([
            makeConfig(id: "llm-keyed", kind: .openAICompatible, order: 0,
                       baseURL: "https://api.example.com/v1", model: "gpt-x"),
            makeConfig(id: "llm-keyless", kind: .openAICompatible, order: 1,
                       baseURL: "https://api.example.com/v1", model: "gpt-x"),
        ])
        let providers = TranslationProviderFactory.makeStreamProviders(
            settings: settings, keychain: keychain)
        XCTAssertEqual(providers.map(\.id), ["llm-keyed"])
    }
}
```

- [ ] **Step 2: Run the test (expect failure).** Run `swift test --filter TranslationProviderFactoryTests`. Expected: compile failure — `TranslationProviderFactory` does not exist yet.

- [ ] **Step 3: Implement `TranslationProviderFactory`.** Create the file. Iterate `settings.enabledServicesInOrder`, switch on `kind`: build Google/Bing directly; build OpenAI only when a non-empty key exists in the keychain and the required `baseURL`/`model` are present; skip `apple` (rendered by a dedicated SwiftUI card, not a stream provider).

```swift
import Foundation

/// Builds the concrete stream `TranslationProvider` instances from the enabled,
/// non-apple service configs (in order). `apple` is intentionally excluded — it
/// is rendered by a dedicated SwiftUI card via `.translationTask`, not as a
/// stream provider. `openAICompatible` reads its secret from the Keychain and is
/// skipped when no key is stored or its baseURL/model are missing.
enum TranslationProviderFactory {
    @MainActor
    static func makeStreamProviders(
        settings: TranslationSettings,
        keychain: TranslationKeychainStore = TranslationKeychainStore(),
        session: URLSession = .shared
    ) -> [any TranslationProvider] {
        var providers: [any TranslationProvider] = []
        for config in settings.enabledServicesInOrder {
            switch config.kind {
            case .apple:
                continue // rendered by AppleTranslationCard, not a stream provider
            case .googleFree:
                providers.append(GoogleFreeTranslationProvider(id: config.id, session: session))
            case .bingFree:
                providers.append(BingFreeTranslationProvider(id: config.id, session: session))
            case .openAICompatible:
                guard let key = keychain.apiKey(for: config.id),
                      !key.isEmpty,
                      let baseURL = config.baseURL, !baseURL.isEmpty,
                      let model = config.model, !model.isEmpty else {
                    continue // no key or incomplete config -> skip silently
                }
                _ = (baseURL, model) // config carries them; provider reads from config
                providers.append(OpenAICompatibleProvider(config: config, apiKey: key, session: session))
            }
        }
        return providers
    }
}
```

- [ ] **Step 4: Run the test (expect pass).** Run `swift test --filter TranslationProviderFactoryTests`. Expected: all tests pass.

- [ ] **Step 5: Commit.** `git add` the two files and commit with:
  ```
  feat(translation): build stream providers from enabled configs
  ```

### Task 12: TranslationCoordinator

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Translation/TranslationCoordinator.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/TranslationCoordinatorTests.swift`

> Depends on `TranslationProvider`, `TranslationRequest`/`TranslationChunk`/`TranslationResult`, `TranslationLanguage`, `LanguageDetector`, and `TranslationSettings` from earlier phases. `history` stays `nil` in tests (do not assert on it).

- [ ] **Step 1: Write the failing test.** Create `TranslationCoordinatorTests.swift`. Define fake providers (a streaming one that yields several `.delta` then `.final`, an erroring one that throws, a one-shot one that yields a single `.final`, and a detecting one that yields `.detected` first). Inject them via `makeProviders`. Assert end states of `results`: per-service status, accumulated text, detected language, failure isolation (one error does not fail the others), `effectiveTarget` second-target rule, and `swapLanguages`.

```swift
import XCTest
@testable import AnyDoor

@MainActor
final class TranslationCoordinatorTests: XCTestCase {
    // A fake provider that replays a fixed chunk script (optionally throwing).
    private struct ScriptedProvider: TranslationProvider {
        let id: String
        let kind: TranslationServiceKind
        let chunks: [TranslationChunk]
        let error: Error?

        init(id: String,
             kind: TranslationServiceKind = .googleFree,
             chunks: [TranslationChunk],
             error: Error? = nil) {
            self.id = id
            self.kind = kind
            self.chunks = chunks
            self.error = error
        }

        func translate(_ request: TranslationRequest) -> AsyncThrowingStream<TranslationChunk, Error> {
            let chunks = self.chunks
            let error = self.error
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    private func makeCoordinator(_ providers: [any TranslationProvider],
                                 defaultsSuite: String = "translation.coord.\(UUID().uuidString)")
    -> TranslationCoordinator {
        let d = UserDefaults(suiteName: defaultsSuite)!
        let settings = TranslationSettings(defaults: d)
        return TranslationCoordinator(settings: settings, makeProviders: { providers })
    }

    private func waitUntil(_ predicate: @escaping () -> Bool,
                           timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testFanOutEndStatesWithFailureIsolation() async {
        let streaming = ScriptedProvider(
            id: "stream",
            chunks: [.delta("Hel"), .delta("lo"), .final("Hello")])
        let erroring = ScriptedProvider(
            id: "err",
            chunks: [],
            error: TranslationProviderError.network("boom"))
        let oneShot = ScriptedProvider(
            id: "once",
            chunks: [.final("Bonjour")])

        let coordinator = makeCoordinator([streaming, erroring, oneShot])
        coordinator.inputText = "Hello"
        coordinator.target = TranslationLanguage.simplifiedChinese
        coordinator.translate()

        await waitUntil {
            coordinator.results.count == 3 &&
            coordinator.results.allSatisfy { $0.status == .success || $0.status == .failure }
        }

        func result(_ id: String) -> TranslationResult? {
            coordinator.results.first { $0.serviceID == id }
        }
        XCTAssertEqual(result("stream")?.status, .success)
        XCTAssertEqual(result("stream")?.text, "Hello")
        XCTAssertEqual(result("once")?.status, .success)
        XCTAssertEqual(result("once")?.text, "Bonjour")
        XCTAssertEqual(result("err")?.status, .failure)
        XCTAssertNotNil(result("err")?.errorMessage)
        // One failure must not knock out the others.
        XCTAssertEqual(result("stream")?.status, .success)
        XCTAssertEqual(result("once")?.status, .success)
    }

    func testDetectedChunkSetsResultDetectedLanguage() async {
        let provider = ScriptedProvider(
            id: "det",
            chunks: [.detected(TranslationLanguage.english), .final("结果")])
        let coordinator = makeCoordinator([provider])
        coordinator.inputText = "hello"
        coordinator.target = TranslationLanguage.simplifiedChinese
        coordinator.translate()

        await waitUntil { coordinator.results.first?.status == .success }
        XCTAssertEqual(coordinator.results.first?.detected, TranslationLanguage.english)
    }

    func testDeltaAccumulation() async {
        let provider = ScriptedProvider(
            id: "acc",
            chunks: [.delta("a"), .delta("b"), .delta("c")]) // no .final
        let coordinator = makeCoordinator([provider])
        coordinator.inputText = "x"
        coordinator.target = TranslationLanguage.simplifiedChinese
        coordinator.translate()

        await waitUntil { coordinator.results.first?.status == .success }
        XCTAssertEqual(coordinator.results.first?.text, "abc")
    }

    func testEffectiveTargetUsesSecondTargetWhenSourceEqualsTarget() {
        let coordinator = makeCoordinator([])
        // settings default: target = systemDefault, second = english.
        coordinator.target = coordinator.target // keep default target
        coordinator.source = coordinator.target // force source == target
        XCTAssertEqual(coordinator.effectiveTarget(), TranslationLanguage.english)
    }

    func testEffectiveTargetUsesTargetWhenSourceDiffers() {
        let coordinator = makeCoordinator([])
        coordinator.target = TranslationLanguage.simplifiedChinese
        coordinator.source = TranslationLanguage.english
        XCTAssertEqual(coordinator.effectiveTarget(), TranslationLanguage.simplifiedChinese)
    }

    func testSwapLanguagesSwapsSourceAndTarget() {
        let coordinator = makeCoordinator([])
        coordinator.source = TranslationLanguage.english
        coordinator.target = TranslationLanguage.simplifiedChinese
        coordinator.swapLanguages()
        XCTAssertEqual(coordinator.source, TranslationLanguage.simplifiedChinese)
        XCTAssertEqual(coordinator.target, TranslationLanguage.english)
    }

    func testEmptyInputProducesNoResults() {
        let provider = ScriptedProvider(id: "p", chunks: [.final("x")])
        let coordinator = makeCoordinator([provider])
        coordinator.inputText = "   "
        coordinator.translate()
        XCTAssertTrue(coordinator.results.isEmpty)
    }
}
```

- [ ] **Step 2: Run the test (expect failure).** Run `swift test --filter TranslationCoordinatorTests`. Expected: compile failure — `TranslationCoordinator` does not exist yet.

- [ ] **Step 3: Implement `TranslationCoordinator`.** Create the file as a `@MainActor @Observable` singleton-able coordinator. `translate()` snapshots input/target, seeds one `.idle` result per provider, fans out one `Task` per provider, transitions `loading -> streaming/success/failure`, accumulates `.delta`, sets `.detected`, isolates failures, and records successes to `history` (nil-safe). `cancel()` cancels all tasks; `effectiveTarget()` applies the second-target rule; `swapLanguages()` swaps; `prefill` sets text and optionally translates.

```swift
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
```

- [ ] **Step 4: Run the test (expect pass).** Run `swift test --filter TranslationCoordinatorTests`. Expected: all tests pass.

- [ ] **Step 5: Verify the wider build still compiles.** Run `swift build`. Expected: builds with no errors (Tasks 9-12 wired together).

- [ ] **Step 6: Commit.** `git add` the two files and commit with:
  ```
  feat(translation): add fan-out TranslationCoordinator
  ```

---

## Phase 3 — Keychain, Settings, Factory, Coordinator (Tasks 9-12)

### Task 13: TranslationRecord @Model + register in ModelContainer

**Files:**
- Create: `Sources/AnyDoor/Models/Translation/TranslationRecord.swift`
- Modify: `Sources/AnyDoor/AppDelegate.swift`
- Modify: `CLAUDE.md`
- Test: `Tests/AnyDoorTests/TranslationRecordTests.swift`

- [ ] **Step 1: Write the failing test for the model.** Create `Tests/AnyDoorTests/TranslationRecordTests.swift`. This proves the init defaults a unique id, stamps `createdAt`, and that the row persists into an in-memory container scoped to `TranslationRecord.self` (the same isolation pattern `ClipboardHistoryStoreTests` uses).

```swift
import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class TranslationRecordTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: TranslationRecord.self, configurations: config)
    }

    func testInitAssignsUniqueIDAndDefaults() {
        let a = TranslationRecord(
            sourceText: "hello",
            translatedText: "你好",
            sourceLangCode: "en",
            targetLangCode: "zh-Hans",
            serviceID: "google",
            serviceName: "Google"
        )
        let b = TranslationRecord(
            sourceText: "hello",
            translatedText: "你好",
            sourceLangCode: "en",
            targetLangCode: "zh-Hans",
            serviceID: "google",
            serviceName: "Google"
        )
        XCTAssertFalse(a.id.isEmpty)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertFalse(a.isFavorite)
        XCTAssertEqual(a.sourceText, "hello")
        XCTAssertEqual(a.translatedText, "你好")
        XCTAssertEqual(a.sourceLangCode, "en")
        XCTAssertEqual(a.targetLangCode, "zh-Hans")
        XCTAssertEqual(a.serviceID, "google")
        XCTAssertEqual(a.serviceName, "Google")
    }

    func testRecordPersistsAndRefetches() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let created = Date(timeIntervalSinceReferenceDate: 1_000)
        let record = TranslationRecord(
            sourceText: "cat",
            translatedText: "猫",
            sourceLangCode: "en",
            targetLangCode: "zh-Hans",
            serviceID: "bing",
            serviceName: "Bing",
            isFavorite: true,
            createdAt: created
        )
        context.insert(record)
        try context.save()

        let rows = try context.fetch(FetchDescriptor<TranslationRecord>())
        let stored = try XCTUnwrap(rows.first)
        XCTAssertEqual(stored.translatedText, "猫")
        XCTAssertTrue(stored.isFavorite)
        XCTAssertEqual(stored.createdAt, created)
    }
}
```

- [ ] **Step 2: Run the test (expect failure).** Run `swift test --filter TranslationRecordTests`. Expected: compile failure — `TranslationRecord` is undefined.

- [ ] **Step 3: Create the model.** Create `Sources/AnyDoor/Models/Translation/TranslationRecord.swift`. Every field carries an inline scalar default so SwiftData lightweight migration can backfill existing rows when this fifth `@Model` joins the schema (the migration rule from CLAUDE.md). `id` is assigned a fresh `UUID().uuidString` in `init` so each row is uniquely identifiable without an `@Attribute(.unique)` (favorites/history toggle by object identity, not by id lookup).

```swift
import Foundation
import SwiftData

/// One persisted translation, written when a stream provider finishes
/// successfully. Powers the favorites + history panel. The fifth `@Model` in
/// the app's ModelContainer schema; all fields keep inline scalar defaults so
/// SwiftData lightweight migration can backfill existing stores.
@Model
final class TranslationRecord {
    var id: String = ""
    var createdAt: Date = Date()
    var sourceText: String = ""
    var translatedText: String = ""
    var sourceLangCode: String = ""
    var targetLangCode: String = ""
    var serviceID: String = ""
    var serviceName: String = ""
    var isFavorite: Bool = false

    init(
        sourceText: String,
        translatedText: String,
        sourceLangCode: String,
        targetLangCode: String,
        serviceID: String,
        serviceName: String,
        isFavorite: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = UUID().uuidString
        self.createdAt = createdAt
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLangCode = sourceLangCode
        self.targetLangCode = targetLangCode
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.isFavorite = isFavorite
    }
}
```

- [ ] **Step 4: Register the model in the ModelContainer.** In `Sources/AnyDoor/AppDelegate.swift`, inside `override init()`, add `TranslationRecord.self` to the schema list.

Before:
```swift
            modelContainer = try ModelContainer(
                for: KeyBinding.self, BuiltinPreference.self, ClipboardHistoryItem.self, HostProfile.self,
                configurations: config
            )
```

After:
```swift
            modelContainer = try ModelContainer(
                for: KeyBinding.self, BuiltinPreference.self, ClipboardHistoryItem.self, HostProfile.self,
                TranslationRecord.self,
                configurations: config
            )
```

- [ ] **Step 5: Update the CLAUDE.md schema note.** In `CLAUDE.md`, find the "Shared ModelContainer / Pinned store path" architecture note that reads "The schema registers exactly four `@Model` types — `KeyBinding`, `BuiltinPreference`, `ClipboardHistoryItem`, `HostProfile`." and change it to:

```
The schema registers exactly five `@Model` types — `KeyBinding`, `BuiltinPreference`, `ClipboardHistoryItem`, `HostProfile`, `TranslationRecord`.
```

- [ ] **Step 6: Run the test (expect pass).** Run `swift test --filter TranslationRecordTests`. Expected: both tests pass.

- [ ] **Step 7: Commit.** `git commit -am "feat(translation): add TranslationRecord model and register schema"`

### Task 14: TranslationHistoryStore

**Files:**
- Create: `Sources/AnyDoor/Services/Translation/TranslationHistoryStore.swift`
- Test: `Tests/AnyDoorTests/TranslationHistoryStoreTests.swift`

- [ ] **Step 1: Write the failing test.** Create `Tests/AnyDoorTests/TranslationHistoryStoreTests.swift`. It wires the store to an in-memory `ModelContainer(for: TranslationRecord.self)` via `configure(modelContainer:)` (mirroring how `ClipboardHistoryStoreTests` calls `bootstrap`), then exercises `record`/`recent`/`favorites`/`toggleFavorite`/`delete`/`clear`/`trim`. Distinct `createdAt` values are written through the model context so ordering is deterministic; `record` itself stamps `Date()`, so the ordering test inserts rows directly to control timestamps and then calls `record` only to assert it persists.

```swift
import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class TranslationHistoryStoreTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: TranslationRecord.self, configurations: config)
    }

    private func makeStore() throws -> (TranslationHistoryStore, ModelContainer) {
        let container = try makeContainer()
        let store = TranslationHistoryStore()
        store.configure(modelContainer: container)
        return (store, container)
    }

    private func insert(
        _ container: ModelContainer,
        text: String,
        favorite: Bool = false,
        at offset: TimeInterval
    ) throws {
        let record = TranslationRecord(
            sourceText: text,
            translatedText: "T-\(text)",
            sourceLangCode: "en",
            targetLangCode: "zh-Hans",
            serviceID: "google",
            serviceName: "Google",
            isFavorite: favorite,
            createdAt: Date(timeIntervalSinceReferenceDate: offset)
        )
        container.mainContext.insert(record)
        try container.mainContext.save()
    }

    func testRecordPersists() throws {
        let (store, container) = try makeStore()
        store.record(
            sourceText: "hello",
            translatedText: "你好",
            source: .english,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google"
        )
        let rows = try container.mainContext.fetch(FetchDescriptor<TranslationRecord>())
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.sourceText, "hello")
        XCTAssertEqual(row.translatedText, "你好")
        XCTAssertEqual(row.sourceLangCode, "en")
        XCTAssertEqual(row.targetLangCode, "zh-Hans")
        XCTAssertEqual(row.serviceID, "google")
    }

    func testRecordWithNilSourceStoresEmptyCode() throws {
        let (store, container) = try makeStore()
        store.record(
            sourceText: "hello",
            translatedText: "你好",
            source: nil,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google"
        )
        let row = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).first)
        XCTAssertEqual(row.sourceLangCode, "")
    }

    func testRecentNewestFirstAndLimit() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        try insert(container, text: "b", at: 200)
        try insert(container, text: "c", at: 300)

        XCTAssertEqual(store.recent(limit: 2).map(\.sourceText), ["c", "b"])
        XCTAssertEqual(store.recent(limit: 10).map(\.sourceText), ["c", "b", "a"])
    }

    func testFavoritesNewestFirst() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "plain", at: 100)
        try insert(container, text: "fav-old", favorite: true, at: 200)
        try insert(container, text: "fav-new", favorite: true, at: 300)

        XCTAssertEqual(store.favorites().map(\.sourceText), ["fav-new", "fav-old"])
    }

    func testToggleFavoriteFlips() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        let row = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertFalse(row.isFavorite)
        store.toggleFavorite(row)
        XCTAssertTrue(try XCTUnwrap(store.recent(limit: 1).first).isFavorite)
        store.toggleFavorite(row)
        XCTAssertFalse(try XCTUnwrap(store.recent(limit: 1).first).isFavorite)
    }

    func testDeleteRemovesRow() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        let row = try XCTUnwrap(store.recent(limit: 1).first)
        store.delete(row)
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).isEmpty)
    }

    func testClearRemovesAll() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        try insert(container, text: "b", at: 200)
        store.clear()
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).isEmpty)
    }

    func testTrimKeepsFavoritesAndNewestNonFavorites() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "old-fav", favorite: true, at: 100)
        try insert(container, text: "n1", at: 200)
        try insert(container, text: "n2", at: 300)
        try insert(container, text: "n3", at: 400)
        try insert(container, text: "n4", at: 500)

        // Keep the 2 newest non-favorites; the favorite is exempt regardless of age.
        store.trim(retention: 2)

        let survivors = Set(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).map(\.sourceText))
        XCTAssertEqual(survivors, ["old-fav", "n4", "n3"])
    }

    func testTrimZeroOrNegativeKeepsEverything() throws {
        let (store, container) = try makeStore()
        try insert(container, text: "a", at: 100)
        try insert(container, text: "b", at: 200)
        store.trim(retention: 0)
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<TranslationRecord>()).count, 2)
    }

    func testNoContextIsSafe() {
        let store = TranslationHistoryStore()
        // No configure() call: every method must be a silent no-op, never crash.
        store.record(
            sourceText: "x",
            translatedText: "y",
            source: .english,
            target: .simplifiedChinese,
            serviceID: "google",
            serviceName: "Google"
        )
        XCTAssertTrue(store.recent(limit: 5).isEmpty)
        XCTAssertTrue(store.favorites().isEmpty)
        store.clear()
    }
}
```

- [ ] **Step 2: Run the test (expect failure).** Run `swift test --filter TranslationHistoryStoreTests`. Expected: compile failure — `TranslationHistoryStore` is undefined.

- [ ] **Step 3: Create the store.** Create `Sources/AnyDoor/Services/Translation/TranslationHistoryStore.swift`. `@MainActor` (mirrors `ClipboardHistoryStore` / `PanelStore`). `configure(modelContainer:)` captures `modelContainer.mainContext` (the same context wiring pattern `ClipboardHistoryStore.bootstrap` uses). Every accessor guards on the optional context and returns an empty/no-op result when unset (proven by `testNoContextIsSafe`). `record` maps a nil source language to an empty `sourceLangCode`. `trim` exempts favorites and keeps the newest `retention` non-favorites; `retention <= 0` is treated as unlimited.

```swift
import Foundation
import SwiftData

/// Persists successful translations and serves the favorites + history panel.
/// `@MainActor` and context-backed, mirroring `ClipboardHistoryStore`: a single
/// shared `mainContext` is captured in `configure` after the ModelContainer is
/// ready (`TranslationHistoryStore.shared.configure(modelContainer:)` from the
/// app). Every method no-ops when no context is wired (unit tests / pre-bootstrap).
@MainActor
final class TranslationHistoryStore {
    static let shared = TranslationHistoryStore()

    private var modelContext: ModelContext?

    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }

    /// Wire the shared container's main context. Mirrors `PanelStore.bootstrap`.
    func configure(modelContainer: ModelContainer) {
        modelContext = modelContainer.mainContext
    }

    /// Write one successful translation. A nil source language (auto-detect that
    /// produced no detection) is stored as an empty code.
    func record(
        sourceText: String,
        translatedText: String,
        source: TranslationLanguage?,
        target: TranslationLanguage,
        serviceID: String,
        serviceName: String
    ) {
        guard let modelContext else { return }
        let record = TranslationRecord(
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLangCode: source?.code ?? "",
            targetLangCode: target.code,
            serviceID: serviceID,
            serviceName: serviceName
        )
        modelContext.insert(record)
        try? modelContext.save()
    }

    /// Newest-first, capped at `limit`.
    func recent(limit: Int) -> [TranslationRecord] {
        guard let modelContext else { return [] }
        var descriptor = FetchDescriptor<TranslationRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// All favorited records, newest first.
    func favorites() -> [TranslationRecord] {
        guard let modelContext else { return [] }
        let descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func toggleFavorite(_ record: TranslationRecord) {
        guard let modelContext else { return }
        record.isFavorite.toggle()
        try? modelContext.save()
    }

    func delete(_ record: TranslationRecord) {
        guard let modelContext else { return }
        modelContext.delete(record)
        try? modelContext.save()
    }

    func clear() {
        guard let modelContext else { return }
        let rows = (try? modelContext.fetch(FetchDescriptor<TranslationRecord>())) ?? []
        for row in rows { modelContext.delete(row) }
        try? modelContext.save()
    }

    /// Keep the newest `retention` non-favorite records; favorites are always
    /// exempt. `retention <= 0` keeps everything (unlimited history).
    func trim(retention: Int) {
        guard let modelContext, retention > 0 else { return }
        let descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { !$0.isFavorite },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let nonFavorites = (try? modelContext.fetch(descriptor)) ?? []
        guard nonFavorites.count > retention else { return }
        for row in nonFavorites[retention...] { modelContext.delete(row) }
        try? modelContext.save()
    }
}
```

- [ ] **Step 4: Run the test (expect pass).** Run `swift test --filter TranslationHistoryStoreTests`. Expected: all tests pass.

- [ ] **Step 5: Commit.** `git commit -am "feat(translation): add TranslationHistoryStore over TranslationRecord"`

### Task 15: SpeechService

**Files:**
- Create: `Sources/AnyDoor/Services/Translation/SpeechService.swift`
- Test: `Tests/AnyDoorTests/SpeechServiceTests.swift`

- [ ] **Step 1: Write the failing test for the pure voice-code picker.** Create `Tests/AnyDoorTests/SpeechServiceTests.swift`. Only the pure `voiceLanguageCode(for:fallbackDetectedCode:)` static is unit-tested (the `AVSpeechSynthesizer` side is runtime/audio and not unit-tested in this repo). It proves: a non-nil language wins; a nil language falls back to the detected code; both nil yields a sensible default; and an empty/blank fallback is treated as absent.

```swift
import XCTest
@testable import AnyDoor

@MainActor
final class SpeechServiceTests: XCTestCase {
    func testLanguageWinsOverFallback() {
        let code = SpeechService.voiceLanguageCode(
            for: .simplifiedChinese,
            fallbackDetectedCode: "ja"
        )
        XCTAssertEqual(code, TranslationLanguage.simplifiedChinese.code)
    }

    func testNilLanguageUsesFallbackDetectedCode() {
        let code = SpeechService.voiceLanguageCode(for: nil, fallbackDetectedCode: "ja")
        XCTAssertEqual(code, "ja")
    }

    func testBlankFallbackIsTreatedAsAbsent() {
        let code = SpeechService.voiceLanguageCode(for: nil, fallbackDetectedCode: "   ")
        XCTAssertEqual(code, "en")
    }

    func testBothAbsentDefaultsToEnglish() {
        XCTAssertEqual(SpeechService.voiceLanguageCode(for: nil, fallbackDetectedCode: nil), "en")
    }
}
```

- [ ] **Step 2: Run the test (expect failure).** Run `swift test --filter SpeechServiceTests`. Expected: compile failure — `SpeechService` is undefined.

- [ ] **Step 3: Create the service.** Create `Sources/AnyDoor/Services/Translation/SpeechService.swift`. `@MainActor` wrapper around a single retained `AVSpeechSynthesizer`. `speak` stops any in-flight utterance first, then enqueues a new one with a voice picked from `voiceLanguageCode`. `isSpeaking` proxies the synthesizer. `voiceLanguageCode` is pure and testable: the explicit language's BCP-47 code wins, else a non-blank detected code, else `"en"`.

```swift
import AVFoundation
import Foundation

/// AVSpeechSynthesizer wrapper for TTS playback of source / translated text.
/// `@MainActor`: AVSpeechSynthesizer is not Sendable and is driven from the UI.
@MainActor
final class SpeechService {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()

    var isSpeaking: Bool { synthesizer.isSpeaking }

    /// Speak `text` in `language` (or, when nil, a best-effort voice). Any
    /// in-flight utterance is cut immediately so back-to-back speaker taps don't
    /// queue up.
    func speak(_ text: String, language: TranslationLanguage?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        let code = Self.voiceLanguageCode(for: language, fallbackDetectedCode: nil)
        utterance.voice = AVSpeechSynthesisVoice(language: code)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Pick a BCP-47 voice code. The explicit language wins; otherwise a
    /// non-blank detected code; otherwise English.
    static func voiceLanguageCode(
        for language: TranslationLanguage?,
        fallbackDetectedCode: String?
    ) -> String {
        if let language { return language.code }
        if let fallback = fallbackDetectedCode?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fallback.isEmpty {
            return fallback
        }
        return "en"
    }
}
```

- [ ] **Step 4: Run the test (expect pass).** Run `swift test --filter SpeechServiceTests`. Expected: all tests pass.

- [ ] **Step 5: Commit.** `git commit -am "feat(translation): add SpeechService TTS wrapper"`

### Task 16: SelectedTextReader

**Files:**
- Create: `Sources/AnyDoor/Services/Translation/SelectedTextReader.swift`
- Test: `Tests/AnyDoorTests/SelectedTextReaderTests.swift`

- [ ] **Step 1: Write the failing test for the clipboard fallback.** Create `Tests/AnyDoorTests/SelectedTextReaderTests.swift`. The AX path needs real focus/permission, so it is not unit-tested; the deterministic `readViaClipboard` is. It uses a throwaway `NSPasteboard(name:)` (same idiom as `ClipboardHistoryStoreTests.testPastePayloadPlainVsRich`), with an injected `copy` closure that synthesizes a selection by writing into that pasteboard, and an injected `settle` that yields immediately. The key assertion is that the caller's prior pasteboard contents are restored afterward, and that a copy producing no change (or empty) returns nil while leaving the pasteboard intact.

```swift
import AppKit
import XCTest
@testable import AnyDoor

@MainActor
final class SelectedTextReaderTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorSel-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func testReadsCopiedSelectionAndRestoresPriorContents() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let text = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            copy: {
                pb.clearContents()
                pb.setString("SELECTED", forType: .string)
            },
            settle: {}
        )

        XCTAssertEqual(text, "SELECTED")
        // Prior pasteboard contents must be restored after the read.
        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
    }

    func testReturnsNilWhenSelectionUnchangedAndRestores() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        // copy() does nothing — simulates "no selection / nothing copied".
        let text = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            copy: {},
            settle: {}
        )

        XCTAssertNil(text)
        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
    }

    func testReturnsNilForWhitespaceOnlySelection() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let text = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            copy: {
                pb.clearContents()
                pb.setString("   \n\t", forType: .string)
            },
            settle: {}
        )

        XCTAssertNil(text)
        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
    }

    func testRestoresEmptyPriorPasteboard() async {
        let pb = makePasteboard()
        pb.clearContents() // no prior string

        let text = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            copy: {
                pb.clearContents()
                pb.setString("SELECTED", forType: .string)
            },
            settle: {}
        )

        XCTAssertEqual(text, "SELECTED")
        // Nothing to restore: the pasteboard string is cleared back to nil.
        XCTAssertNil(pb.string(forType: .string))
    }
}
```

- [ ] **Step 2: Run the test (expect failure).** Run `swift test --filter SelectedTextReaderTests`. Expected: compile failure — `SelectedTextReader` is undefined.

- [ ] **Step 3: Create the reader.** Create `Sources/AnyDoor/Services/Translation/SelectedTextReader.swift`. `read()` first tries the Accessibility path: the system-wide focused UI element's `kAXSelectedTextAttribute`; on empty/failure it falls back to `readViaClipboard`, which snapshots the current pasteboard string, fires a synthesized Cmd-C (the injected `copy`), waits for the OS to settle, reads the result only if the `changeCount` advanced and the string is non-blank, then restores the snapshot regardless. The change-count gate is what makes "nothing was selected" return nil instead of re-reading the prior clipboard. The default `copy`/`settle` for the real path post a Cmd-C CGEvent pair and sleep ~120 ms.

```swift
import AppKit
import ApplicationServices
import Foundation

/// Reads the user's current text selection: the Accessibility
/// `kAXSelectedTextAttribute` of the focused element first, with a
/// pasteboard-preserving Cmd-C fallback when AX yields nothing.
enum SelectedTextReader {
    /// Best-effort selected text. Tries AX, then the clipboard fallback.
    @MainActor
    static func read() async -> String? {
        if let ax = readViaAccessibility() { return ax }
        return await readViaClipboard(
            pasteboard: .general,
            copy: { synthesizeCopy() },
            settle: { try? await Task.sleep(nanoseconds: 120_000_000) }
        )
    }

    /// The focused element's selected text via the Accessibility API. Returns
    /// nil when there is no focused element, the attribute is unavailable, or
    /// the selection is blank.
    @MainActor
    static func readViaAccessibility() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let element = focused else {
            return nil
        }
        // `focused` is an AXUIElement; force-cast through CFTypeRef is safe here.
        let axElement = element as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axElement, kAXSelectedTextAttribute as CFString, &selected
        ) == .success, let string = selected as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : string
    }

    /// Pasteboard fallback: snapshot the current string, trigger `copy`, wait
    /// for `settle`, then read the copied selection only if the pasteboard's
    /// `changeCount` advanced and the result is non-blank. The prior contents
    /// are always restored before returning.
    static func readViaClipboard(
        pasteboard: NSPasteboard,
        copy: () -> Void,
        settle: @Sendable () async -> Void
    ) async -> String? {
        let previous = pasteboard.string(forType: .string)
        let beforeCount = pasteboard.changeCount

        copy()
        await settle()

        var result: String?
        if pasteboard.changeCount != beforeCount {
            let copied = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let copied, !copied.isEmpty {
                result = pasteboard.string(forType: .string)
            }
        }

        // Restore the caller's pasteboard regardless of outcome.
        pasteboard.clearContents()
        if let previous {
            pasteboard.setString(previous, forType: .string)
        }
        return result
    }

    /// Post a synthesized Cmd-C key-down/up pair to the focused app.
    @MainActor
    private static func synthesizeCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKeyCode: CGKeyCode = 8 // 'c'
        let down = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 4: Run the test (expect pass).** Run `swift test --filter SelectedTextReaderTests`. Expected: all four tests pass, proving the pasteboard is restored in every branch.

- [ ] **Step 5: Build the whole target.** Run `swift build`. Expected: clean build (confirms the AX/CGEvent imports compile under Swift 6 strict concurrency).

- [ ] **Step 6: Commit.** `git commit -am "feat(translation): add SelectedTextReader with AX and clipboard fallback"`

---

## Phase 4 — Persistence & Support Services (Tasks 13-16)

### Task 17: TranslationWindowController

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Views/Translation/TranslationWindowController.swift`
- Verify: `swift build`

- [ ] **Step 1: Create the controller file with a key-capable floating panel.** Mirror `CommandPaletteWindowController` (NSPanel, `.floating`, `canJoinAllSpaces`) and `ClipboardTextWindow`'s `KeyableTextPanel` (a panel subclass that overrides `canBecomeKey`). Esc + click-outside monitors are installed only while NOT pinned; pinning removes them. The frame is saved on move/resize and restored on show under `windowFrameKey`. Write the complete file:

```swift
import AppKit
import SwiftUI

/// Spotlight-style floating panel hosting the translation UI. The panel can
/// become key (so the input TextEditor takes keystrokes) and remembers its frame
/// under `windowFrameKey`. While unpinned it dismisses on Esc or an outside
/// click (Spotlight UX); pinning removes those monitors so the window stays put
/// and behaves like a normal floating utility window.
@MainActor
final class TranslationWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TranslationWindowController()

    static let windowFrameKey = "translation.windowFrame"

    private(set) var isPinned: Bool = false
    private var keyMonitor: Any?
    private var mouseMonitors: [Any] = []

    private init() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 420, height: 420)
        panel.setFrameAutosaveName("")

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func toggle() {
        if window?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        guard let window else { return }
        mountContentIfNeeded()
        restoreFrame()

        // Activate first so a `.accessory` app summoned from a global hotkey can
        // actually make the panel key (see CommandPaletteWindowController for the
        // full rationale on the focus oscillation otherwise).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        installKeyMonitor()
        if !isPinned { installDismissMonitors() }
    }

    func showPrefilled(_ text: String) {
        show()
        TranslationCoordinator.shared.prefill(text, autoTranslate: true)
    }

    func close() {
        saveFrame()
        removeKeyMonitor()
        removeDismissMonitors()
        window?.orderOut(nil)
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        if pinned {
            // Pinned windows stay put: drop the Spotlight dismissal monitors.
            removeDismissMonitors()
        } else if window?.isVisible == true {
            installDismissMonitors()
        }
    }

    private func mountContentIfNeeded() {
        guard let window, window.contentView == nil || !(window.contentView is NSHostingView<TranslationView>) else { return }
        let view = TranslationView(controller: self)
        let host = NSHostingView(rootView: view)
        host.frame = window.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        window.contentView = host
    }

    // MARK: - Frame persistence

    private func restoreFrame() {
        guard let window else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.windowFrameKey) {
            let rect = NSRectFromString(saved)
            if rect.width > 0, rect.height > 0, visibleOnAnyScreen(rect) {
                window.setFrame(rect, display: false)
                return
            }
        }
        positionAtCenter()
    }

    private func saveFrame() {
        guard let window, window.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.windowFrameKey)
    }

    private func visibleOnAnyScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
    }

    private func positionAtCenter() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - visible.height * 0.15
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Monitors

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let consumed = MainThreadIsolation.run { self?.handle(keyCode: keyCode) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handle(keyCode: UInt16) -> Bool {
        guard let window, window.isVisible, window.isKeyWindow else { return false }
        // Esc dismisses only when unpinned; a pinned window ignores it so the
        // input field can be cleared without losing the window.
        if keyCode == 53, !isPinned {
            close()
            return true
        }
        return false
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            MainThreadIsolation.run {
                if event.window !== self.window { self.close() }
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainThreadIsolation.run { self?.close() }
        }
        mouseMonitors = [local, global].compactMap { $0 }
    }

    private func removeDismissMonitors() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    /// Unpinned windows dismiss when focus leaves (Spotlight UX); pinned ones
    /// stay visible in the background.
    func windowDidResignKey(_ notification: Notification) {
        guard !isPinned else { return }
        close()
    }
}

/// Titled panels can become key already, but a panel built to behave like a
/// utility/floating window needs `canBecomeKey` forced on so the embedded
/// TextEditor can take keystrokes even when the app is `.accessory`.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 2: Build.** Run `swift build`.
  Expected: the package compiles (a single use of `TranslationView` / `TranslationCoordinator` exists; if `TranslationView` is not yet present, this task is built after Task 21 — build with Task 21's stub view in place or temporarily comment the `mountContentIfNeeded` body until Task 21 lands). Resolve any errors before committing.

- [ ] **Step 3: Manual verify (after Task 21).** `swift run AnyDoor`, trigger the "open translation window" hotkey: the panel appears centered, accepts typing, dismisses on Esc and on an outside click. Move/resize it, close, reopen — the frame is restored. Toggle pin (Task 21 button): outside clicks and Esc no longer dismiss it.

- [ ] **Step 4: Commit.**
```
feat(translation): add pinnable floating translation panel controller
```

### Task 18: LanguageBar

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Views/Translation/LanguageBar.swift`
- Verify: `swift build`

- [ ] **Step 1: Create the LanguageBar view.** A source picker (with an "Auto Detect" entry that maps to `nil`), a swap button, and a target picker. It binds to `TranslationCoordinator` (`source`, `target`, `detectedSource`, `swapLanguages()`). Selecting a target re-translates is left to the caller's `onChange`; the bar only mutates the coordinator. Write the complete file:

```swift
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
```

- [ ] **Step 2: Add the L10n keys.** Ensure these keys exist in the `.xcstrings` catalog (Chinese UI strings) and as `L10n.Key` cases: `translationSwapLanguages` ("交换语言"), `translationAutoDetect` ("自动检测"), `translationAutoDetectHint` ("自动检测（%@）"). Add them the same way nearby keys are declared (search for an existing key like `clipboardActionEdit` to find the catalog file and the `L10n.Key` enum, then mirror the pattern). Keep one `%@` placeholder in `translationAutoDetectHint`.

- [ ] **Step 3: Build.** Run `swift build`.
  Expected: compiles cleanly with the new keys resolved.

- [ ] **Step 4: Manual verify (after Task 21).** Open the translation window: the source menu lists "Auto Detect" first then the catalog; with auto active and detectable input typed, the source button shows the detected-language hint. The swap button exchanges source/target. The target menu shows a checkmark on the active language.

- [ ] **Step 5: Commit.**
```
feat(translation): add source/swap/target language bar
```

### Task 19: TranslationServiceCard

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Views/Translation/TranslationServiceCard.swift`
- Verify: `swift build`

- [ ] **Step 1: Create the card view.** One card per stream-provider `TranslationResult`: header (SF Symbol + service name + collapse chevron), body (translated text or a state indicator), and a footer with speaker (→ `SpeechService`) and copy (→ `NSPasteboard`, with clipboard-history suppression like the palette copy paths). Handle `.idle/.loading/.streaming/.success/.failure`. Mirror `ClipboardCardView`'s material/rounded-rect styling and the palette's copy-with-`noteSelfWrite` idiom. Write the complete file:

```swift
import AppKit
import SwiftUI

/// A single translation result rendered as a stacked card. Header shows the
/// service icon, name, and a collapse chevron; the body shows the translated
/// text or a loading/error state; the footer offers TTS and copy. Apple's
/// on-device translation is NOT rendered here — it has its own card.
struct TranslationServiceCard: View {
    let config: TranslationServiceConfig
    let result: TranslationResult
    /// Resolved target/detected language used to pick a TTS voice.
    let target: TranslationLanguage
    let detectedFallbackCode: String?

    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                Divider()
                body(for: result)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: config.iconName)
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(config.displayName)
                .font(.subheadline.weight(.semibold))
            statusBadge
            Spacer()
            footerButtons
            Button {
                collapsed.toggle()
            } label: {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L(collapsed ? .translationExpand : .translationCollapse))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch result.status {
        case .loading:
            ProgressView().controlSize(.small)
        case .streaming:
            ProgressView().controlSize(.small)
        default:
            EmptyView()
        }
    }

    /// Speaker + copy, shown only once there is text to act on.
    @ViewBuilder
    private var footerButtons: some View {
        if !result.text.isEmpty {
            Button {
                SpeechService.shared.speak(result.text, language: voiceLanguage)
            } label: {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L(.translationSpeak))

            Button {
                copyToPasteboard(result.text)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L(.translationCopy))
        }
    }

    @ViewBuilder
    private func body(for result: TranslationResult) -> some View {
        switch result.status {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                LocalizedText(.translationTranslating).foregroundStyle(.secondary).font(.callout)
            }
        case .streaming, .success:
            Text(result.text.isEmpty ? " " : result.text)
                .font(.body)
                .textSelection(.enabled)
        case .failure:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(result.errorMessage ?? L(.translationError))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Detected source informs the spoken voice for the translation: the target
    /// language is what was produced, so it drives the voice.
    private var voiceLanguage: TranslationLanguage? {
        result.detected ?? target
    }

    /// Copy and suppress clipboard-history capture, matching every other
    /// internal copy path (Calc / PickColor / OCR / QRCode / Screenshot).
    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }
}
```

- [ ] **Step 2: Add the L10n keys.** Add `L10n.Key` cases and `.xcstrings` entries (Chinese): `translationExpand` ("展开"), `translationCollapse` ("收起"), `translationSpeak` ("朗读"), `translationCopy` ("复制"), `translationTranslating` ("翻译中…"), `translationError` ("翻译失败"). Reuse the existing `toastCopiedToClipboard` key (already referenced by the palette). Mirror the declaration pattern of nearby keys.

- [ ] **Step 3: Build.** Run `swift build`.
  Expected: compiles; `SpeechService.shared.speak`, `ClipboardWatcher.shared?.noteSelfWrite`, and `ToastPresenter.shared.show` all resolve.

- [ ] **Step 4: Manual verify (after Task 21).** Translate a phrase: each non-Apple card shows a spinner while loading, fills with text (streaming for an LLM), exposes speaker (audible TTS) and copy (toast confirms, clipboard contains the translation). The collapse chevron hides/shows the body. A provider error renders the failure row.

- [ ] **Step 5: Commit.**
```
feat(translation): add per-service result card with TTS and copy
```

### Task 20: AppleTranslationCard

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Views/Translation/AppleTranslationCard.swift`
- Verify: `swift build`

- [ ] **Step 1: Create the Apple on-device card.** Gated `#available(macOS 15, *)`; uses the `.translationTask` modifier driven by the coordinator's input + resolved source/target. It is NOT a stream provider. On macOS 14 the card renders nothing (the host filters it out, but guard here too). Match the visual chrome of `TranslationServiceCard`. Write the complete file:

```swift
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// Apple's on-device Translation rendered by a dedicated SwiftUI card via the
/// `.translationTask` modifier (macOS 15+). Unlike the network/LLM services this
/// is not a TranslationProvider — Apple's API binds directly to the view. On
/// macOS 14 the card is empty (the host also filters the apple config out).
struct AppleTranslationCard: View {
    let config: TranslationServiceConfig
    @Bindable var coordinator: TranslationCoordinator

    var body: some View {
        if #available(macOS 15, *) {
            AppleTranslationCardBody(config: config, coordinator: coordinator)
        } else {
            EmptyView()
        }
    }
}

#if canImport(Translation)
@available(macOS 15, *)
private struct AppleTranslationCardBody: View {
    let config: TranslationServiceConfig
    @Bindable var coordinator: TranslationCoordinator

    @State private var configuration: TranslationSession.Configuration?
    @State private var output: String = ""
    @State private var status: TranslationResult.Status = .idle
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Rebuild the session whenever the input or languages change; the
        // coordinator's translate() bumps these the same way the stream path does.
        .onChange(of: triggerKey) { _, _ in refreshConfiguration() }
        .onAppear { refreshConfiguration() }
        .translationTask(configuration) { session in
            await run(session)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: config.iconName)
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(config.displayName)
                .font(.subheadline.weight(.semibold))
            if status == .loading || status == .streaming {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if !output.isEmpty {
                Button {
                    SpeechService.shared.speak(output, language: coordinator.effectiveTarget())
                } label: {
                    Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L(.translationSpeak))

                Button {
                    copy(output)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L(.translationCopy))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                LocalizedText(.translationTranslating).foregroundStyle(.secondary).font(.callout)
            }
        case .streaming, .success:
            Text(output.isEmpty ? " " : output)
                .font(.body)
                .textSelection(.enabled)
        case .failure:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(errorMessage ?? L(.translationError)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// A value that changes whenever any input affecting the translation changes,
    /// so onChange can rebuild the session configuration.
    private var triggerKey: String {
        let src = (coordinator.source ?? coordinator.detectedSource)?.code ?? "auto"
        return "\(coordinator.inputText)\u{1}\(src)\u{1}\(coordinator.effectiveTarget().code)"
    }

    /// Rebuild the configuration only when there is text to translate. Passing a
    /// fresh Configuration value re-runs `.translationTask`. A nil source lets
    /// Apple auto-detect.
    private func refreshConfiguration() {
        let text = coordinator.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            status = .idle
            output = ""
            configuration = nil
            return
        }
        let sourceLocale = (coordinator.source ?? coordinator.detectedSource)
            .flatMap { Locale.Language(identifier: $0.code) }
        let targetLocale = Locale.Language(identifier: coordinator.effectiveTarget().code)
        status = .loading
        output = ""
        errorMessage = nil
        configuration = TranslationSession.Configuration(source: sourceLocale, target: targetLocale)
    }

    private func run(_ session: TranslationSession) async {
        let text = coordinator.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let response = try await session.translate(text)
            output = response.targetText
            status = .success
        } catch is CancellationError {
            // Superseded by a newer request; leave state for the new run.
        } catch {
            errorMessage = error.localizedDescription
            status = .failure
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }
}
#endif
```

- [ ] **Step 2: Confirm the Translation framework imports.** Run `swift build` and check there is no missing-module error for `Translation`. If `#available(macOS 15, *)` paired with `#if canImport(Translation)` compiles on the deployment target (macOS 14), proceed. If `TranslationSession.Configuration(source:target:)` or `session.translate(_:)` signatures differ for the installed SDK, adjust the call sites to the SDK's API (do not change the gating). Use `npx ctx7@latest` for the current Apple Translation API if the build flags a signature mismatch.
  Expected: compiles on the macOS 14 deployment target with the framework guarded.

- [ ] **Step 3: Manual verify (macOS 15+ only).** On a macOS 15+ machine, open the window, type text: the Apple card translates on-device (first use may prompt to download a language model). Speaker and copy work. On macOS 14 the Apple service is absent from the stack.

- [ ] **Step 4: Commit.**
```
feat(translation): add Apple on-device translation card via translationTask
```

### Task 21: TranslationView

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Views/Translation/TranslationView.swift`
- Verify: `swift build`

- [ ] **Step 1: Create the root view.** Assemble: a toolbar (pin toggle, history, screenshot-translate, settings/gear), an input area (TextEditor + a "Recognized as" chip + speaker + copy, with Enter triggering `coordinator.translate()`), the `LanguageBar`, and an ordered results stack — generic `TranslationServiceCard` for each stream service in `enabledServicesInOrder`, the `AppleTranslationCard` for the apple config. Auto-speak the first successful result when `settings.autoSpeak`. Write the complete file:

```swift
import AppKit
import SwiftUI

/// Root translation panel UI: toolbar, input editor, language bar, and the
/// stacked result cards (one generic card per stream service in configured
/// order, plus the dedicated Apple card on macOS 15+). Enter in the input
/// triggers a fan-out translation; auto-speak narrates the first success.
struct TranslationView: View {
    let controller: TranslationWindowController

    @State private var coordinator = TranslationCoordinator.shared
    @State private var settings = TranslationSettings.shared
    @State private var isPinned: Bool
    /// serviceIDs already auto-spoken for the current translation run, so the
    /// "first success" narration fires exactly once per run.
    @State private var autoSpokenRun = false
    @FocusState private var inputFocused: Bool

    init(controller: TranslationWindowController) {
        self.controller = controller
        _isPinned = State(initialValue: controller.isPinned)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    inputCard
                    LanguageBar(coordinator: coordinator) { runTranslation() }
                    resultCards
                }
                .padding(14)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onChange(of: coordinator.results.map(\.status)) { _, _ in autoSpeakIfNeeded() }
        .onAppear { inputFocused = true }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 14) {
            Spacer()
            toolbarButton(systemImage: isPinned ? "pin.fill" : "pin", help: L(.translationPin)) {
                isPinned.toggle()
                controller.setPinned(isPinned)
            }
            toolbarButton(systemImage: "clock.arrow.circlepath", help: L(.translationHistory)) {
                showHistory()
            }
            toolbarButton(systemImage: "camera.viewfinder", help: L(.translationScreenshot)) {
                controller.close()
                Task { await PanelStore.shared.run(.screenshotTranslate) }
            }
            toolbarButton(systemImage: "gearshape", help: L(.translationSettings)) {
                SettingsOpener.shared.open()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func toolbarButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: - Input

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                EnterToTranslateEditor(text: $coordinator.inputText) { runTranslation() }
                    .frame(minHeight: 70, maxHeight: 140)
                    .focused($inputFocused)
                if coordinator.inputText.isEmpty {
                    LocalizedText(.translationInputPlaceholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                if let detected = coordinator.detectedSource, coordinator.source == nil {
                    Text(L(.translationRecognizedAs, detected.displayName()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Spacer()
                if !coordinator.inputText.isEmpty {
                    Button {
                        SpeechService.shared.speak(coordinator.inputText, language: coordinator.source ?? coordinator.detectedSource)
                    } label: {
                        Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L(.translationSpeak))
                    Button {
                        copy(coordinator.inputText)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L(.translationCopy))
                }
            }
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: coordinator.inputText) { _, _ in coordinator.updateDetection() }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultCards: some View {
        let target = coordinator.effectiveTarget()
        ForEach(settings.enabledServicesInOrder) { config in
            if config.kind == .apple {
                AppleTranslationCard(config: config, coordinator: coordinator)
            } else if let result = coordinator.results.first(where: { $0.serviceID == config.id }) {
                TranslationServiceCard(
                    config: config,
                    result: result,
                    target: target,
                    detectedFallbackCode: coordinator.detectedSource?.code
                )
            }
        }
    }

    // MARK: - Actions

    private func runTranslation() {
        autoSpokenRun = false
        coordinator.translate()
    }

    private func showHistory() {
        // History UI lives in the settings tab; surface it there for now.
        SettingsOpener.shared.open()
    }

    /// On the first card that flips to `.success` after a run, speak it once
    /// when the user enabled auto-speak.
    private func autoSpeakIfNeeded() {
        guard settings.autoSpeak, !autoSpokenRun else { return }
        guard let firstSuccess = coordinator.results.first(where: { $0.status == .success && !$0.text.isEmpty }) else { return }
        autoSpokenRun = true
        SpeechService.shared.speak(firstSuccess.text, language: firstSuccess.detected ?? coordinator.effectiveTarget())
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }
}

/// An NSTextView-backed multiline editor where a bare Return triggers
/// translation (Shift+Return inserts a newline). SwiftUI's TextEditor can't
/// intercept Return cleanly, so this thin AppKit bridge does.
private struct EnterToTranslateEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.string = text
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: EnterToTranslateEditor
        init(_ parent: EnterToTranslateEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        /// Bare Return submits; Shift+Return falls through to insert a newline.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if !shift {
                    parent.onSubmit()
                    return true
                }
            }
            return false
        }
    }
}
```

- [ ] **Step 2: Add the L10n keys.** Add `L10n.Key` cases and `.xcstrings` entries (Chinese): `translationPin` ("固定窗口"), `translationHistory` ("历史记录"), `translationScreenshot` ("截图翻译"), `translationSettings` ("设置"), `translationInputPlaceholder` ("输入要翻译的文本…"), `translationRecognizedAs` ("识别为：%@"). Reuse `translationSpeak` / `translationCopy` / `toastCopiedToClipboard` from earlier tasks. Mirror the nearby key declaration pattern; keep one `%@` placeholder in `translationRecognizedAs`.

- [ ] **Step 3: Confirm `SettingsOpener` API.** Open `Services/Core/SettingsOpener.swift` and confirm the open method name (`SettingsOpener.shared.open()`); if it differs (e.g. `openSettings()`), adjust the two call sites in this view to match. Do not invent a new method.

- [ ] **Step 4: Build.** Run `swift build`.
  Expected: the full package compiles, including Tasks 17-20.

- [ ] **Step 5: Manual verify.** `swift run AnyDoor`, open the translation window. Type a phrase and press Enter (Shift+Enter inserts a newline instead): cards for Google/Bing (and any configured LLM) populate concurrently; on macOS 15+ the Apple card translates too. The "Recognized as" chip shows the detected language in auto mode. The pin button keeps the window open on outside clicks; the gear opens Settings; the screenshot button closes the window and starts region capture. With auto-speak on (Translation settings), the first successful card is read aloud once.

- [ ] **Step 6: Commit.**
```
feat(translation): assemble translation panel view with toolbar, input, and result stack
```

---

## Phase 5 — Window & UI (Tasks 17-21)

### Task 22: Add the three translate cases to `BuiltinItem` and all its switches

> **Execution-order correction (discovered during implementation):** Task 21's `TranslationView` toolbar calls `PanelStore.shared.run(.screenshotTranslate)`, so it cannot build until this task's `BuiltinItem.screenshotTranslate` case exists. **Do this task's enum/switch additions (and the three `builtin.translate*` L10n keys its `titleKey` switch needs, per the Localization policy) before Task 21's view is committed.** Because `L10n.swift` / `Localizable.xcstrings` carry both tasks' string additions, commit `BuiltinItem.swift` + the shared L10n/xcstrings + this task's test together, then commit `TranslationView.swift` separately.

**Files:**
- Modify: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Models/BuiltinItem.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/BuiltinItemTranslateTests.swift` (new)

- [ ] **Step 1: Write the failing test for the three new cases.**
  Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/BuiltinItemTranslateTests.swift`. This mirrors the XCTest style of `BuiltinItemBrightnessTests.swift` (the repo uses XCTest for `BuiltinItem` tests).

  ```swift
  import XCTest
  @testable import AnyDoor

  final class BuiltinItemTranslateTests: XCTestCase {
      func testNewCasesExist() {
          XCTAssertNotNil(BuiltinItem(rawValue: "translate"))
          XCTAssertNotNil(BuiltinItem(rawValue: "screenshotTranslate"))
          XCTAssertNotNil(BuiltinItem(rawValue: "translateSelection"))
      }

      func testTranslateKindsAreAction() {
          XCTAssertEqual(BuiltinItem.translate.kind, .action)
          XCTAssertEqual(BuiltinItem.screenshotTranslate.kind, .action)
          XCTAssertEqual(BuiltinItem.translateSelection.kind, .action)
      }

      func testTranslateTitleKeys() {
          XCTAssertEqual(BuiltinItem.translate.titleKey, .builtinTranslate)
          XCTAssertEqual(BuiltinItem.screenshotTranslate.titleKey, .builtinScreenshotTranslate)
          XCTAssertEqual(BuiltinItem.translateSelection.titleKey, .builtinTranslateSelection)
      }

      func testTranslateSymbols() {
          XCTAssertEqual(BuiltinItem.translate.symbol, "character.bubble")
          XCTAssertEqual(BuiltinItem.screenshotTranslate.symbol, "text.viewfinder")
          XCTAssertEqual(BuiltinItem.translateSelection.symbol, "text.cursor")
      }

      func testTranslateDefaultOrders() {
          XCTAssertEqual(BuiltinItem.translate.defaultOrder, 980)
          XCTAssertEqual(BuiltinItem.screenshotTranslate.defaultOrder, 982)
          XCTAssertEqual(BuiltinItem.translateSelection.defaultOrder, 984)
      }

      func testTranslateDoesNotRequireAutomation() {
          XCTAssertFalse(BuiltinItem.translate.requiresAutomation)
          XCTAssertFalse(BuiltinItem.screenshotTranslate.requiresAutomation)
          XCTAssertFalse(BuiltinItem.translateSelection.requiresAutomation)
      }

      func testTranslateDefaultVisibilityTrue() {
          XCTAssertTrue(BuiltinItem.translate.defaultVisibility)
          XCTAssertTrue(BuiltinItem.screenshotTranslate.defaultVisibility)
          XCTAssertTrue(BuiltinItem.translateSelection.defaultVisibility)
      }

      func testTranslateInAllCases() {
          XCTAssertTrue(BuiltinItem.allCases.contains(.translate))
          XCTAssertTrue(BuiltinItem.allCases.contains(.screenshotTranslate))
          XCTAssertTrue(BuiltinItem.allCases.contains(.translateSelection))
      }
  }
  ```

- [ ] **Step 2: Run the test and confirm it fails to compile.**
  ```bash
  swift test --filter BuiltinItemTranslateTests
  ```
  Expected result: a compile error — `BuiltinItem` has no member `translate` / `.builtinTranslate` does not exist. This is the expected red state (the `L10n.Key` cases land in Task 25; if you run before Task 25 the title-key references won't resolve, so it is fine to revisit this run after Task 25 — for now confirm the missing-`BuiltinItem`-case errors appear).

- [ ] **Step 3: Add the three enum cases.**
  In `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Models/BuiltinItem.swift`, add the cases immediately after `case bluetoothBattery` (the last case, line 61):

  ```swift
      case bluetoothBattery
      case translate
      case screenshotTranslate
      case translateSelection
  ```

- [ ] **Step 4: Add the cases to the `kind` switch (`.action`).**
  In the `.action` branch of `var kind`, extend the final `captureScrolling` line so the three new items are grouped with the other actions:

  ```swift
              .captureWindow, .captureFullscreen, .captureTimer, .captureModeBar, .recordScreen,
              .captureScrolling,
              .translate, .screenshotTranslate, .translateSelection: return .action
  ```
  (Replace the existing `.captureScrolling: return .action` line with the two lines above.)

- [ ] **Step 5: Add the cases to the `titleKey` switch.**
  Add these three lines after `case .bluetoothBattery:  return .builtinBluetoothBattery` inside `var titleKey`:

  ```swift
          case .bluetoothBattery:  return .builtinBluetoothBattery
          case .translate:           return .builtinTranslate
          case .screenshotTranslate: return .builtinScreenshotTranslate
          case .translateSelection:  return .builtinTranslateSelection
  ```

- [ ] **Step 6: Add the cases to the `symbol` switch.**
  Add these three lines after `case .bluetoothBattery: return "battery.100"` inside `var symbol`:

  ```swift
          case .bluetoothBattery: return "battery.100"
          case .translate: return "character.bubble"
          case .screenshotTranslate: return "text.viewfinder"
          case .translateSelection: return "text.cursor"
  ```

- [ ] **Step 7: Add the cases to the `defaultOrder` switch.**
  Add these three lines after `case .bluetoothBattery: return 1980` inside `var defaultOrder`:

  ```swift
          case .bluetoothBattery: return 1980
          case .translate: return 980
          case .screenshotTranslate: return 982
          case .translateSelection: return 984
  ```

- [ ] **Step 8: Confirm the remaining switches need no change.**
  `historyKind` ends in `default: return nil` (translate items are not history buckets), `requiresAutomation` ends in `default: return false`, and `feedbackSound` ends in `default: return nil` — all three new cases fall through to those defaults, which is exactly the desired behavior. `defaultVisibility` switches on `self.kind`, and `.action` already maps to `true`, so visibility is correct with no edit. Make no changes to these four computed properties.

- [ ] **Step 9: Re-run the test.**
  ```bash
  swift test --filter BuiltinItemTranslateTests
  ```
  Expected result: all `BuiltinItemTranslateTests` pass (this requires the `L10n.Key` cases from Task 25 to exist; if you are executing tasks in order, run this again after Task 25 and confirm green). The `BuiltinItem` switches are exhaustive, so the whole target compiles.

- [ ] **Step 10: Commit.**
  ```bash
  git add Sources/AnyDoor/Models/BuiltinItem.swift Tests/AnyDoorTests/BuiltinItemTranslateTests.swift
  git commit -m "feat(translation): add translate builtin items to the catalog"
  ```

### Task 23: The three translate `ActionProvider` classes

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Providers/TranslateProvider.swift`
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Providers/ScreenshotTranslateProvider.swift`
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/Providers/TranslateSelectionProvider.swift`

> These are AppKit/window-coupled providers (they drive `TranslationWindowController.shared`, an NSPanel). The repo does not unit-test these provider classes (see `ClipboardWallProvider`, which has no test), so this task uses `swift build` plus a manual verification step rather than TDD.

- [ ] **Step 1: Create `TranslateProvider`.**
  This mirrors `ClipboardWallProvider` exactly: a `@MainActor final class` `ActionProvider` whose `run()` toggles the window controller.

  ```swift
  import AppKit

  /// Bridges the translation window into the panel's `ActionProvider` surface so
  /// it gets a panel row, settings visibility/order, and a bindable hotkey via
  /// the existing dispatch path. `@MainActor` because it drives an NSPanel.
  @MainActor
  final class TranslateProvider: ActionProvider {
      let itemKey: BuiltinItem = .translate
      var permission: PermissionStatus { .notRequired }

      func run() async throws {
          TranslationWindowController.shared.toggle()
      }
  }
  ```

- [ ] **Step 2: Create `ScreenshotTranslateProvider`.**
  Captures a region, OCRs it, joins the lines, and prefills the translation window. Errors are absorbed into a toast (mirroring `OCRProvider`); a user cancel is silent.

  ```swift
  import AppKit
  import Foundation

  /// Captures a screen region, recognizes its text with Vision, then opens the
  /// translation window prefilled with that text (auto-translating immediately).
  ///
  /// User cancellation is silent; every error is mapped to a toast and `run()`
  /// never propagates. `@MainActor` because it drives an NSPanel and toasts.
  @MainActor
  final class ScreenshotTranslateProvider: ActionProvider {
      let itemKey: BuiltinItem = .screenshotTranslate
      var permission: PermissionStatus { .notRequired }

      func run() async throws {
          do {
              guard let image = try await RegionCapture.captureRegion() else {
                  return // user cancelled — silent, no toast
              }
              let lines = try await TextRecognizer.recognize(image)
              guard !lines.isEmpty else {
                  ToastPresenter.shared.show(.failure(L(.toastOcrNoText)))
                  return
              }
              let text = lines.joined(separator: "\n")
              TranslationWindowController.shared.showPrefilled(text)
          } catch OCRError.screenCapturePermissionDenied {
              ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
          } catch {
              ToastPresenter.shared.show(.failure(L(.toastRecognitionFailed)))
          }
      }
  }
  ```

- [ ] **Step 3: Create `TranslateSelectionProvider`.**
  Reads the current selection (AX first, clipboard fallback) and prefills the window. A nil/empty selection is silent.

  ```swift
  import AppKit
  import Foundation

  /// Reads the user's currently selected text (Accessibility first, clipboard
  /// copy fallback) and opens the translation window prefilled with it.
  ///
  /// An empty or unreadable selection is silent. `@MainActor` because it reads
  /// the focused AX element and drives an NSPanel.
  @MainActor
  final class TranslateSelectionProvider: ActionProvider {
      let itemKey: BuiltinItem = .translateSelection
      var permission: PermissionStatus { .notRequired }

      func run() async throws {
          guard let text = await SelectedTextReader.read() else { return }
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty else { return }
          TranslationWindowController.shared.showPrefilled(text)
      }
  }
  ```

- [ ] **Step 4: Build.**
  ```bash
  swift build
  ```
  Expected result: the target compiles. (Depends on `TranslationWindowController`, `SelectedTextReader`, and the `BuiltinItem` cases from Task 22 already existing.)

- [ ] **Step 5: Manual verification.**
  Run `swift run AnyDoor`. In Settings → Panel, confirm three new rows appear: "翻译", "截图翻译", "划词翻译" (action type badge). Open the panel and click "翻译" — the translation window toggles open/closed. Select text in any app, then trigger "划词翻译" from the panel — the window opens prefilled with the selected text and auto-translates. Trigger "截图翻译" — a region selector appears; drag a region with text and confirm the window opens prefilled with the recognized text.

- [ ] **Step 6: Commit.**
  ```bash
  git add Sources/AnyDoor/Services/Providers/TranslateProvider.swift Sources/AnyDoor/Services/Providers/ScreenshotTranslateProvider.swift Sources/AnyDoor/Services/Providers/TranslateSelectionProvider.swift
  git commit -m "feat(translation): add translate, screenshot-translate and selection-translate providers"
  ```

### Task 24: Register the providers in `AppDelegate` and wire the history store / coordinator

**Files:**
- Modify: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/AppDelegate.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/BuiltinPreferenceSeederTranslateTests.swift` (new)

- [ ] **Step 1: Register the three providers in the `providers` array.**
  In `AppDelegate.applicationDidFinishLaunching`, add the three providers immediately after `ClipboardWallProvider(),` (the last element, line 136), before the closing `]`:

  ```swift
              ClipboardWallProvider(),
              TranslateProvider(),
              ScreenshotTranslateProvider(),
              TranslateSelectionProvider(),
          ]
  ```

- [ ] **Step 2: Wire the history store and coordinator after `PanelStore.bootstrap`.**
  Right after the existing `HostsManager.shared.bootstrap(modelContainer: modelContainer)` line (currently line 139), add the translation history wiring. This mirrors the `ClipboardHistoryStore.shared.bootstrap(modelContainer:)` pattern already used above for clipboard.

  ```swift
          HostsManager.shared.bootstrap(modelContainer: modelContainer)

          // Translation history: give the store the shared container, then point
          // the coordinator at it so successful translations get recorded.
          TranslationHistoryStore.shared.configure(modelContainer: modelContainer)
          TranslationCoordinator.shared.history = TranslationHistoryStore.shared
  ```

- [ ] **Step 3: Add `TranslationRecord.self` to the `ModelContainer` schema.**
  Find the `ModelContainer(for:...)` construction in `AppDelegate.init()` and add `TranslationRecord.self` to the type list (it becomes the 5th registered `@Model`):

  ```swift
          let container = try ModelContainer(
              for: KeyBinding.self,
                  BuiltinPreference.self,
                  ClipboardHistoryItem.self,
                  HostProfile.self,
                  TranslationRecord.self,
              configurations: config
          )
  ```
  (Match whatever surrounding `do/try`/variable name the file already uses — only insert the `TranslationRecord.self,` line into the existing type list. All `TranslationRecord` scalar fields carry inline defaults, so SwiftData lightweight migration backfills cleanly.)

- [ ] **Step 4: Add `TranslationSettings` reload to `reconcileAfterImport`.**
  In `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/BackupService.swift`, add the reload alongside the other settings reloads in `reconcileAfterImport()` (after `CaptureSettings.shared.reloadFromDefaults()`):

  ```swift
          CaptureSettings.shared.reloadFromDefaults()
          TranslationSettings.shared.reloadFromDefaults()
  ```

- [ ] **Step 5: Write the seeder verification test (auto-seed confirmation).**
  `BuiltinPreferenceSeeder` needs no code change — it iterates `BuiltinItem.allCases`, so the three new items are picked up automatically and appended at `maxOrder + 100` on upgrade (or get their `defaultOrder` on a fresh install). Prove this with a test. Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/BuiltinPreferenceSeederTranslateTests.swift`, matching the XCTest + in-memory-`ModelContext` style of `BuiltinPreferenceSeederTests.swift`.

  ```swift
  import XCTest
  import SwiftData
  @testable import AnyDoor

  final class BuiltinPreferenceSeederTranslateTests: XCTestCase {
      private func makeInMemoryContext() throws -> ModelContext {
          let schema = Schema([
              KeyBinding.self,
              BuiltinPreference.self,
              ClipboardHistoryItem.self,
          ])
          let config = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
          let container = try ModelContainer(for: schema, configurations: [config])
          return ModelContext(container)
      }

      @MainActor
      func testTranslateItemsAreSeededVisibleOnEmptyStore() throws {
          let ctx = try makeInMemoryContext()
          BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

          let prefs = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
          for key in ["translate", "screenshotTranslate", "translateSelection"] {
              let row = try XCTUnwrap(prefs.first { $0.itemKey == key }, "missing \(key)")
              XCTAssertTrue(row.isVisible, "\(key) should seed visible")
          }
      }

      @MainActor
      func testTranslateItemsAppendedOnUpgrade() throws {
          let ctx = try makeInMemoryContext()

          // Simulate an existing install that predates the translate items.
          ctx.insert(BuiltinPreference(itemKey: BuiltinItem.keepAwake.rawValue,
                                       isVisible: true,
                                       displayOrder: 50))
          try ctx.save()

          BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

          let prefs = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
          for key in ["translate", "screenshotTranslate", "translateSelection"] {
              let row = try XCTUnwrap(prefs.first { $0.itemKey == key }, "missing \(key)")
              XCTAssertGreaterThan(row.displayOrder, 50, "\(key) should append after existing rows")
          }
      }
  }
  ```

- [ ] **Step 6: Run the seeder test.**
  ```bash
  swift test --filter BuiltinPreferenceSeederTranslateTests
  ```
  Expected result: both tests pass — confirming the seeder auto-handles the new items with no seeder code change.

- [ ] **Step 7: Build the whole app.**
  ```bash
  swift build
  ```
  Expected result: compiles clean with the new providers registered, the 5-model schema, and the coordinator/history wiring in place.

- [ ] **Step 8: Commit.**
  ```bash
  git add Sources/AnyDoor/AppDelegate.swift Sources/AnyDoor/Services/BackupService.swift Tests/AnyDoorTests/BuiltinPreferenceSeederTranslateTests.swift
  git commit -m "feat(translation): register translate providers and wire history store"
  ```

### Task 25: Add `L10n.Key` cases + `Localizable.xcstrings` entries (en + zh-Hans)

**Files:**
- Modify: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Utilities/L10n.swift`
- Modify: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Resources/Localizable.xcstrings`

> `LocalizationCoverageTests.test_everyL10nKeyHasZhHansAndEnTranslations` already asserts that every `L10n.Key` has both `en` and `zh-Hans` entries. Use that as the failing/passing gate (TDD without writing a new test).

> **Canonical list — reconcile, don't duplicate.** This task is the authoritative list of every translation `L10n.Key`. Some keys below were already added inline by earlier UI tasks (per the Localization policy at the top of this plan). For each key in this task: **add it only if its `case` does not already exist**; re-declaring an existing `case` is a compile error. After this task, every rendered translation string must map to exactly one key here.

- [ ] **Step 1: Add the new `L10n.Key` cases.**
  In `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Utilities/L10n.swift`, add the following cases just before the closing comment `// Migration tasks append cases here.` (these cover the three builtin titles, the settings tab, and the translation window UI strings):

  ```swift
          // MARK: Translation
          case builtinTranslate = "builtin.translate"
          case builtinScreenshotTranslate = "builtin.screenshotTranslate"
          case builtinTranslateSelection = "builtin.translateSelection"
          case settingsTabTranslation = "settings.tab.translation"
          case translationInputPlaceholder = "translation.input.placeholder"
          case translationTranslateButton = "translation.translate.button"
          case translationDetectAuto = "translation.detect.auto"
          case translationDetected = "translation.detected"
          case translationSwapLanguages = "translation.swapLanguages"
          case translationSourceLanguage = "translation.sourceLanguage"
          case translationTargetLanguage = "translation.targetLanguage"
          case translationCopy = "translation.copy"
          case translationSpeak = "translation.speak"
          case translationStopSpeaking = "translation.stopSpeaking"
          case translationPin = "translation.pin"
          case translationUnpin = "translation.unpin"
          case translationCollapse = "translation.collapse"
          case translationExpand = "translation.expand"
          case translationStatusLoading = "translation.status.loading"
          case translationStatusFailure = "translation.status.failure"
          case translationFavorite = "translation.favorite"
          case translationUnfavorite = "translation.unfavorite"
          case translationHistoryTitle = "translation.history.title"
          case translationFavoritesTitle = "translation.favorites.title"
          case translationHistoryEmpty = "translation.history.empty"
          case translationHistoryClear = "translation.history.clear"
          case settingsTranslationServicesSection = "settings.translation.servicesSection"
          case settingsTranslationTargetLanguage = "settings.translation.targetLanguage"
          case settingsTranslationSecondTargetLanguage = "settings.translation.secondTargetLanguage"
          case settingsTranslationAutoSpeak = "settings.translation.autoSpeak"
          case settingsTranslationAddService = "settings.translation.addService"
          case settingsTranslationRemoveService = "settings.translation.removeService"
          case settingsTranslationApiKey = "settings.translation.apiKey"
          case settingsTranslationBaseURL = "settings.translation.baseURL"
          case settingsTranslationModel = "settings.translation.model"
  ```

- [ ] **Step 2: Run the coverage test and confirm it fails.**
  ```bash
  swift test --filter LocalizationCoverageTests
  ```
  Expected result: failure listing each new key as `(no entry)` — every new `L10n.Key` lacks an `xcstrings` entry. This is the expected red state.

- [ ] **Step 3: Add the `xcstrings` entries.**
  In `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Resources/Localizable.xcstrings`, add one entry per new key under the top-level `"strings"` object. Each entry follows the exact shape the existing catalog uses (see `"builtin.ocr"` / `"builtin.scheduledShutdown"`): a key with `"extractionState": "manual"` and a `"localizations"` map carrying `en` and `zh-Hans` `stringUnit`s with `"state": "translated"`. Three representative entries showing the exact required shape:

  ```json
      "builtin.translate" : {
        "extractionState" : "manual",
        "localizations" : {
          "en" : {
            "stringUnit" : {
              "state" : "translated",
              "value" : "Translate"
            }
          },
          "zh-Hans" : {
            "stringUnit" : {
              "state" : "translated",
              "value" : "翻译"
            }
          }
        }
      },
      "settings.tab.translation" : {
        "extractionState" : "manual",
        "localizations" : {
          "en" : {
            "stringUnit" : {
              "state" : "translated",
              "value" : "Translation"
            }
          },
          "zh-Hans" : {
            "stringUnit" : {
              "state" : "translated",
              "value" : "翻译"
            }
          }
        }
      },
      "translation.input.placeholder" : {
        "extractionState" : "manual",
        "localizations" : {
          "en" : {
            "stringUnit" : {
              "state" : "translated",
              "value" : "Enter text to translate"
            }
          },
          "zh-Hans" : {
            "stringUnit" : {
              "state" : "translated",
              "value" : "输入要翻译的文本"
            }
          }
        }
      },
  ```

- [ ] **Step 4: Add the remaining entries using the same shape.**
  Add an entry (identical structure to Step 3) for every other new key, with these en / zh-Hans values:

  ```text
  builtin.screenshotTranslate          → "Screenshot Translate"      / "截图翻译"
  builtin.translateSelection           → "Translate Selection"       / "划词翻译"
  translation.translate.button         → "Translate"                 / "翻译"
  translation.detect.auto              → "Auto Detect"               / "自动检测"
  translation.detected                 → "Detected: %@"              / "已检测：%@"
  translation.swapLanguages            → "Swap Languages"            / "交换语言"
  translation.sourceLanguage           → "Source Language"           / "源语言"
  translation.targetLanguage           → "Target Language"           / "目标语言"
  translation.copy                     → "Copy"                      / "复制"
  translation.speak                    → "Speak"                     / "朗读"
  translation.stopSpeaking             → "Stop"                      / "停止"
  translation.pin                      → "Pin Window"                / "固定窗口"
  translation.unpin                    → "Unpin Window"              / "取消固定"
  translation.collapse                 → "Collapse"                  / "收起"
  translation.expand                   → "Expand"                    / "展开"
  translation.status.loading           → "Translating…"              / "翻译中…"
  translation.status.failure           → "Translation failed"        / "翻译失败"
  translation.favorite                 → "Add to Favorites"          / "收藏"
  translation.unfavorite               → "Remove from Favorites"     / "取消收藏"
  translation.history.title            → "History"                   / "历史"
  translation.favorites.title          → "Favorites"                 / "收藏夹"
  translation.history.empty            → "No history yet"            / "暂无历史"
  translation.history.clear            → "Clear History"             / "清空历史"
  settings.translation.servicesSection → "Translation Services"      / "翻译服务"
  settings.translation.targetLanguage  → "Target Language"           / "目标语言"
  settings.translation.secondTargetLanguage → "Second Target Language" / "第二目标语言"
  settings.translation.autoSpeak       → "Auto-speak result"         / "自动朗读结果"
  settings.translation.addService      → "Add Service"               / "添加服务"
  settings.translation.removeService   → "Remove"                    / "移除"
  settings.translation.apiKey          → "API Key"                   / "API 密钥"
  settings.translation.baseURL         → "Base URL"                  / "接口地址"
  settings.translation.model           → "Model"                     / "模型"
  ```

- [ ] **Step 5: Validate the JSON is well-formed.**
  ```bash
  python3 -m json.tool /Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Resources/Localizable.xcstrings > /dev/null && echo OK
  ```
  Expected result: prints `OK` (the catalog is valid JSON — a trailing comma or missing brace would error here).

- [ ] **Step 6: Re-run the coverage test.**
  ```bash
  swift test --filter LocalizationCoverageTests
  ```
  Expected result: passes — every `L10n.Key`, including the new translation keys, has both `en` and `zh-Hans` translations.

- [ ] **Step 7: Confirm the Task 22 title-key test now resolves.**
  ```bash
  swift test --filter BuiltinItemTranslateTests
  ```
  Expected result: passes — `.builtinTranslate` / `.builtinScreenshotTranslate` / `.builtinTranslateSelection` now exist and resolve to non-empty translations.

- [ ] **Step 8: Commit.**
  ```bash
  git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
  git commit -m "feat(translation): localize translate builtins, settings tab and window strings"
  ```

---

## Phase 6 — Builtins, Entry Providers, Seeding, Localization (Tasks 22-25)

### Task 26: TranslationSettingsView + add the Translation tab to SettingsView

**Files:**
- Create: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Views/TranslationSettingsView.swift`
- Modify: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Views/SettingsView.swift`

This is an AppKit/SwiftUI-heavy view that the repo does not unit-test, so verification is `swift build` + a manual checklist (mirror how `CaptureSettingsView` is structured: `Form` + `.formStyle(.grouped)`, explicit `Binding(get:set:)` into the settings setters).

- [ ] **Step 1: Add the L10n keys this view needs.** Open the string catalog and add these keys (Chinese values; English values too). Use `L10n.Key` cases that match. Add to `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Resources/Localizable.xcstrings` (locate the catalog with `find Sources -name '*.xcstrings'` first if the path differs) and to the `L10n.Key` enum (search for `case settingsTabCapture` to find the file). Required keys and their Chinese strings:

```
settingsTabTranslation            = "翻译"
settingsTranslationLanguageSection = "语言"
settingsTranslationTargetLanguage  = "目标语言"
settingsTranslationSecondTarget    = "备用目标语言"
settingsTranslationSecondTargetFooter = "当检测到的源语言与目标语言相同时，改用此语言。"
settingsTranslationAutoSpeak       = "翻译后自动朗读"
settingsTranslationServicesSection = "翻译服务"
settingsTranslationAddService      = "添加服务"
settingsTranslationServiceName     = "名称"
settingsTranslationServiceBaseURL  = "Base URL"
settingsTranslationServiceModel    = "模型"
settingsTranslationServiceAPIKey   = "API Key"
settingsTranslationServicePrompt   = "提示词模板"
settingsTranslationServiceTest     = "测试"
settingsTranslationServiceTesting  = "测试中…"
settingsTranslationServiceTestOK   = "连接成功"
settingsTranslationServiceTestFailed = "连接失败"
settingsTranslationHistorySection  = "历史记录"
settingsTranslationHistoryRetention = "保留条数"
settingsTranslationHistoryClear    = "清空历史"
settingsTranslationRemove          = "移除"
settingsTranslationEdit            = "编辑"
```

Follow the exact JSON shape of an existing entry in the catalog (each key is an object with `"extractionState": "manual"` and a `"localizations"` map for `"en"` and `"zh-Hans"`). Add the matching `case` lines to `L10n.Key`.

- [ ] **Step 2: Create `TranslationSettingsView.swift` (top of file + language/auto-speak/history sections).** Write the full file now; the next step appends the service-config sheet. Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Views/TranslationSettingsView.swift`:

```swift
import SwiftUI
import AppKit

/// Settings pane for the translation feature. Binds to the shared
/// `TranslationSettings` (UserDefaults-backed `@Observable`) through its
/// explicit setters so the live coordinator sees changes immediately, mirroring
/// `CaptureSettingsView`.
@MainActor
struct TranslationSettingsView: View {
    @State private var settings = TranslationSettings.shared
    @State private var history = TranslationHistoryStore.shared
    private let keychain = TranslationKeychainStore()

    @State private var editingConfig: TranslationServiceConfig?
    @State private var isPresentingNew = false
    @State private var historyRetention: Int = 200

    var body: some View {
        Form {
            languageSection
            servicesSection
            historySection
        }
        .formStyle(.grouped)
        .sheet(item: $editingConfig) { config in
            TranslationServiceConfigSheet(
                config: config,
                isNew: isPresentingNew,
                keychain: keychain
            ) { saved, apiKey in
                if let apiKey { keychain.setAPIKey(apiKey, for: saved.id) }
                settings.upsertService(saved)
                editingConfig = nil
                isPresentingNew = false
            } onCancel: {
                editingConfig = nil
                isPresentingNew = false
            }
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        Section {
            Picker(selection: targetLanguage) {
                ForEach(TranslationLanguage.catalog) { lang in
                    Text(lang.displayName()).tag(lang.code)
                }
            } label: {
                LocalizedText(.settingsTranslationTargetLanguage)
            }

            Picker(selection: secondTargetLanguage) {
                ForEach(TranslationLanguage.catalog) { lang in
                    Text(lang.displayName()).tag(lang.code)
                }
            } label: {
                LocalizedText(.settingsTranslationSecondTarget)
            }

            Toggle(isOn: autoSpeak) { LocalizedText(.settingsTranslationAutoSpeak) }
        } header: {
            LocalizedText(.settingsTranslationLanguageSection)
        } footer: {
            LocalizedText(.settingsTranslationSecondTargetFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Services

    private var servicesSection: some View {
        Section {
            ForEach(settings.services) { config in
                serviceRow(config)
            }
            .onMove { indices, newOffset in
                var reordered = settings.services
                reordered.move(fromOffsets: indices, toOffset: newOffset)
                for (index, var config) in reordered.enumerated() {
                    config.order = index
                    reordered[index] = config
                }
                settings.setServices(reordered)
            }

            Button {
                let new = TranslationServiceConfig(
                    id: UUID().uuidString,
                    kind: .openAICompatible,
                    displayName: "OpenAI",
                    iconName: "brain",
                    enabled: true,
                    order: settings.services.count,
                    baseURL: "https://api.openai.com/v1",
                    model: "gpt-4o-mini",
                    promptTemplate: TranslationServiceConfig.defaultPromptTemplate
                )
                isPresentingNew = true
                editingConfig = new
            } label: {
                Label { LocalizedText(.settingsTranslationAddService) } icon: { Image(systemName: "plus") }
            }
        } header: {
            LocalizedText(.settingsTranslationServicesSection)
        }
    }

    @ViewBuilder
    private func serviceRow(_ config: TranslationServiceConfig) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: enabledBinding(config)) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)

            Image(systemName: config.iconName)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text(config.displayName)
            Spacer()

            if config.kind == .openAICompatible {
                Button { isPresentingNew = false; editingConfig = config } label: {
                    LocalizedText(.settingsTranslationEdit)
                }
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    keychain.deleteAPIKey(for: config.id)
                    settings.removeService(id: config.id)
                } label: {
                    LocalizedText(.settingsTranslationRemove)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            Stepper(value: $historyRetention, in: 20...2000, step: 20) {
                Text(L(.settingsTranslationHistoryRetention) + ": \(historyRetention)")
            }
            .onChange(of: historyRetention) { _, newValue in
                history.trim(retention: newValue)
            }

            Button(role: .destructive) {
                history.clear()
            } label: {
                LocalizedText(.settingsTranslationHistoryClear)
            }
        } header: {
            LocalizedText(.settingsTranslationHistorySection)
        }
    }

    // MARK: - Bindings into TranslationSettings setters

    private var targetLanguage: Binding<String> {
        Binding(get: { settings.targetLanguageCode }, set: { settings.setTargetLanguageCode($0) })
    }
    private var secondTargetLanguage: Binding<String> {
        Binding(get: { settings.secondTargetLanguageCode }, set: { settings.setSecondTargetLanguageCode($0) })
    }
    private var autoSpeak: Binding<Bool> {
        Binding(get: { settings.autoSpeak }, set: { settings.setAutoSpeak($0) })
    }
    private func enabledBinding(_ config: TranslationServiceConfig) -> Binding<Bool> {
        Binding(
            get: { settings.services.first(where: { $0.id == config.id })?.enabled ?? config.enabled },
            set: { newValue in
                var updated = config
                updated.enabled = newValue
                settings.upsertService(updated)
            }
        )
    }
}
```

- [ ] **Step 3: Append the OpenAI-compatible config sheet to the same file.** Add `TranslationServiceConfigSheet` to the bottom of `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Views/TranslationSettingsView.swift`:

```swift
/// Sheet for creating/editing an OpenAI-compatible LLM instance. The API key is
/// stored in (and pre-loaded from) the Keychain via `TranslationKeychainStore`;
/// it is never persisted into `TranslationServiceConfig`.
@MainActor
private struct TranslationServiceConfigSheet: View {
    @State private var draft: TranslationServiceConfig
    @State private var apiKey: String
    @State private var testState: TestState = .idle
    private let isNew: Bool
    private let keychain: TranslationKeychainStore
    private let onSave: (TranslationServiceConfig, String?) -> Void
    private let onCancel: () -> Void

    private enum TestState: Equatable { case idle, testing, success, failure(String) }

    init(
        config: TranslationServiceConfig,
        isNew: Bool,
        keychain: TranslationKeychainStore,
        onSave: @escaping (TranslationServiceConfig, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: config)
        _apiKey = State(initialValue: keychain.apiKey(for: config.id) ?? "")
        self.isNew = isNew
        self.keychain = keychain
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField(text: $draft.displayName) { LocalizedText(.settingsTranslationServiceName) }
                    TextField(text: baseURL) { LocalizedText(.settingsTranslationServiceBaseURL) }
                    TextField(text: model) { LocalizedText(.settingsTranslationServiceModel) }
                    SecureField(text: $apiKey) { LocalizedText(.settingsTranslationServiceAPIKey) }
                }

                Section {
                    TextEditor(text: promptTemplate)
                        .font(.body.monospaced())
                        .frame(minHeight: 80)
                } header: {
                    LocalizedText(.settingsTranslationServicePrompt)
                }

                Section {
                    HStack(spacing: 10) {
                        Button { runTest() } label: {
                            LocalizedText(.settingsTranslationServiceTest)
                        }
                        .disabled(testState == .testing)

                        switch testState {
                        case .idle:
                            EmptyView()
                        case .testing:
                            LocalizedText(.settingsTranslationServiceTesting)
                                .foregroundStyle(.secondary)
                        case .success:
                            Label { LocalizedText(.settingsTranslationServiceTestOK) } icon: {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            .foregroundStyle(.green)
                        case .failure(let message):
                            Label { Text(message) } icon: { Image(systemName: "xmark.circle.fill") }
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(role: .cancel) { onCancel() } label: { Text(verbatim: "Cancel") }
                    .keyboardShortcut(.cancelAction)
                Button {
                    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(draft, trimmedKey.isEmpty ? nil : trimmedKey)
                } label: { Text(verbatim: "Save") }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 460, height: 480)
    }

    private var baseURL: Binding<String> {
        Binding(get: { draft.baseURL ?? "" }, set: { draft.baseURL = $0 })
    }
    private var model: Binding<String> {
        Binding(get: { draft.model ?? "" }, set: { draft.model = $0 })
    }
    private var promptTemplate: Binding<String> {
        Binding(
            get: { draft.promptTemplate ?? TranslationServiceConfig.defaultPromptTemplate },
            set: { draft.promptTemplate = $0 }
        )
    }

    private func runTest() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            testState = .failure(L(.settingsTranslationServiceTestFailed))
            return
        }
        let config = draft
        testState = .testing
        Task {
            let provider = OpenAICompatibleProvider(config: config, apiKey: trimmedKey)
            let request = TranslationRequest(
                text: "Hello",
                source: TranslationLanguage.english,
                target: TranslationLanguage.simplifiedChinese
            )
            do {
                var received = false
                for try await chunk in provider.translate(request) {
                    switch chunk {
                    case .delta(let s) where !s.isEmpty: received = true
                    case .final(let s) where !s.isEmpty: received = true
                    default: break
                    }
                }
                testState = received ? .success : .failure(L(.settingsTranslationServiceTestFailed))
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
```

- [ ] **Step 4: Add the Translation tab to `SettingsView`.** In `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Views/SettingsView.swift`, insert a tab between `CaptureSettingsView` and `GeneralSettingsView`:

```swift
            TranslationSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabTranslation) } icon: { Image(systemName: "character.bubble") }
                }
```

So the `TabView` body reads (replace the existing block):

```swift
            CaptureSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabCapture) } icon: { Image(systemName: "camera.viewfinder") }
                }

            TranslationSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabTranslation) } icon: { Image(systemName: "character.bubble") }
                }

            GeneralSettingsView()
                .tabItem {
                    Label { LocalizedText(.settingsTabGeneral) } icon: { Image(systemName: "gear") }
                }
```

- [ ] **Step 5: Build.** Run:

```bash
swift build
```

Expected result: the build succeeds with no errors (warnings about the new view are acceptable). If `L10n.Key` reports a missing case, return to Step 1 and add the missing key + catalog entry.

- [ ] **Step 6: Manual verification.** Run `swift run AnyDoor`, open Settings, click the new "翻译" (Translation) tab. Verify:
  - Target language and 备用目标语言 (second target) pickers list the catalog languages and persist after closing/reopening Settings.
  - The auto-speak toggle flips and persists.
  - The default services list shows Apple / Google / Bing rows (Apple has no Edit/Remove buttons; the OpenAI rows do).
  - "添加服务" opens the config sheet; fill name/baseURL/model/key, the "测试" button shows 测试中… then 连接成功/连接失败. Save adds a row; toggling its enable switch persists; Remove deletes it.
  - The history retention stepper and "清空历史" button render.

- [ ] **Step 7: Commit.**

```bash
git add -A && git commit -m "feat(translation): add Translation settings tab with service config sheet"
```

### Task 27: Register translation keys in SyncSettingsRegistry + wire BackupService reconcile

**Files:**
- Modify: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/SyncSettingsRegistry.swift`
- Modify: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/BackupService.swift`
- Test: `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/SyncSettingsRegistryTranslationTests.swift`

The repo unit-tests `SyncSettingsRegistry` round-trips via `BackupService`-style XCTest; TDD here.

- [ ] **Step 1: Write the failing test.** Create `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Tests/AnyDoorTests/SyncSettingsRegistryTranslationTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class SyncSettingsRegistryTranslationTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "SyncRegistryTranslation.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testTranslationKeysAreWhitelisted() {
        let keys = Set(SyncSettingsRegistry.entries.map(\.key))
        XCTAssertTrue(keys.contains("translation.targetLanguage"))
        XCTAssertTrue(keys.contains("translation.secondTargetLanguage"))
        XCTAssertTrue(keys.contains("translation.autoSpeak"))
        XCTAssertTrue(keys.contains("translation.services"))
    }

    func testTranslationKeysHaveExpectedTypes() {
        let byKey = Dictionary(uniqueKeysWithValues: SyncSettingsRegistry.entries.map { ($0.key, $0.type) })
        XCTAssertEqual(byKey["translation.targetLanguage"], .string)
        XCTAssertEqual(byKey["translation.secondTargetLanguage"], .string)
        XCTAssertEqual(byKey["translation.autoSpeak"], .bool)
        XCTAssertEqual(byKey["translation.services"], .string)
    }

    func testTranslationKeysRoundTrip() {
        let source = makeDefaults()
        source.set("ja", forKey: "translation.targetLanguage")
        source.set("en", forKey: "translation.secondTargetLanguage")
        source.set(true, forKey: "translation.autoSpeak")
        source.set("[{\"id\":\"x\"}]", forKey: "translation.services")

        let captured = SyncSettingsRegistry.read(from: source)
        XCTAssertEqual(captured["translation.targetLanguage"], .string("ja"))
        XCTAssertEqual(captured["translation.secondTargetLanguage"], .string("en"))
        XCTAssertEqual(captured["translation.autoSpeak"], .bool(true))
        XCTAssertEqual(captured["translation.services"], .string("[{\"id\":\"x\"}]"))

        let destination = makeDefaults()
        let applied = SyncSettingsRegistry.write(captured, to: destination)
        XCTAssertEqual(applied, 4)
        XCTAssertEqual(destination.string(forKey: "translation.targetLanguage"), "ja")
        XCTAssertEqual(destination.string(forKey: "translation.secondTargetLanguage"), "en")
        XCTAssertTrue(destination.bool(forKey: "translation.autoSpeak"))
        XCTAssertEqual(destination.string(forKey: "translation.services"), "[{\"id\":\"x\"}]")
    }
}
```

Make `ValueType` equatable in the assertion: `SyncSettingsRegistry.ValueType` must conform to `Equatable` for `XCTAssertEqual`. If it does not already, add `Equatable` in Step 2.

- [ ] **Step 2: Run the test (expect failure).**

```bash
swift test --filter SyncSettingsRegistryTranslationTests
```

Expected result: compile failure or assertion failures — the four `translation.*` keys are not in `entries` yet (and `ValueType` may not be `Equatable`).

- [ ] **Step 3: Add the four keys to `SyncSettingsRegistry.entries`.** In `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/SyncSettingsRegistry.swift`, make `ValueType` equatable and append the translation entries. Replace the `enum ValueType` line:

```swift
    enum ValueType: Equatable { case bool, int, string, stringArray }
```

Then append these four entries to the `entries` array, immediately before the closing `]` (after the `capture.overlayTimeout` entry):

```swift
        Entry(key: "translation.targetLanguage", type: .string),
        Entry(key: "translation.secondTargetLanguage", type: .string),
        Entry(key: "translation.autoSpeak", type: .bool),
        Entry(key: "translation.services", type: .string),
```

- [ ] **Step 4: Run the test (expect pass).**

```bash
swift test --filter SyncSettingsRegistryTranslationTests
```

Expected result: all three tests pass.

- [ ] **Step 5: Wire `TranslationSettings.reloadFromDefaults()` into `BackupService.reconcileAfterImport()`.** In `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Services/BackupService.swift`, inside `reconcileAfterImport()`, add the reload call next to the other settings reloads. Replace:

```swift
        CaptureSettings.shared.reloadFromDefaults()
        ClipboardTagStore.shared.reload()
```

with:

```swift
        CaptureSettings.shared.reloadFromDefaults()
        TranslationSettings.shared.reloadFromDefaults()
        ClipboardTagStore.shared.reload()
```

- [ ] **Step 6: Build to confirm reconcile compiles.**

```bash
swift build
```

Expected result: build succeeds. `TranslationSettings.shared.reloadFromDefaults()` resolves (`reloadFromDefaults()` is in the contract).

- [ ] **Step 7: Commit.**

```bash
git add -A && git commit -m "feat(translation): make translation settings portable via SyncSettingsRegistry"
```

### Task 28: Final integration build + end-to-end verification gate

**Files:**
- Verify (read, no edits expected unless a gap is found): `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/AppDelegate.swift`, `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Models/BuiltinItem.swift`

This task wires the last loose ends from prior phases and gates the whole feature. No new unit tests; it is an integration build plus a manual end-to-end checklist.

- [ ] **Step 1: Confirm the 5th model is registered.** Open `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/AppDelegate.swift` and confirm the `ModelContainer(for:)` schema includes `TranslationRecord.self`. It must read:

```swift
KeyBinding.self, BuiltinPreference.self, ClipboardHistoryItem.self, HostProfile.self, TranslationRecord.self
```

If `TranslationRecord.self` is absent, add it to the `ModelContainer(for:)` call (Phase requirement from the model task). Do not change the pinned store URL.

- [ ] **Step 2: Confirm history store + coordinator are bootstrapped.** Still in `AppDelegate.swift`, confirm `applicationDidFinishLaunching` (a) calls `TranslationHistoryStore.shared.configure(modelContainer:)` with the shared container, and (b) sets `TranslationCoordinator.shared.history = TranslationHistoryStore.shared`. If either is missing, add them immediately after the existing `PanelStore.shared.bootstrap(modelContainer:providers:)` call:

```swift
        TranslationHistoryStore.shared.configure(modelContainer: modelContainer)
        TranslationCoordinator.shared.history = TranslationHistoryStore.shared
```

- [ ] **Step 3: Confirm the three translate providers are in the providers array + builtins exist.** In `AppDelegate.swift` confirm the `providers` array passed to `bootstrap` contains `TranslateProvider()`, `ScreenshotTranslateProvider()`, and `TranslateSelectionProvider()`. In `/Users/zingerbee/Documents/worktree/AnyDoor/tr/Sources/AnyDoor/Models/BuiltinItem.swift` confirm cases `.translate` / `.screenshotTranslate` / `.translateSelection` exist with kind `.action` and default orders 980/982/984. If any provider is missing from the array, add the three instances alongside the other `BuiltinProvider` entries. (Do not author special default hotkeys — `BuiltinPreferenceSeeder` auto-appends the new items.)

- [ ] **Step 4: Clean integration build.**

```bash
swift build
```

Expected result: the full app builds with no errors. Resolve any unresolved symbol here before continuing (most likely a missing provider/model registration from Steps 1-3).

- [ ] **Step 5: Manual end-to-end verification.** Run the app and exercise the full feature:

```bash
swift run AnyDoor
```

Grant Accessibility if prompted, then verify each item:
  - [ ] Set the three global hotkeys in Settings (open window / screenshot translate / translate selection). The "open window" hotkey shows the floating translation panel; it is Spotlight-style and remembers its frame after move + close + reopen.
  - [ ] Type a sentence in the input and press ENTER. Google and Bing cards appear and populate; source language is auto-detected; the language bar shows the detected source and lets you swap source/target.
  - [ ] If on macOS 15+, the Apple on-device Translation card renders via `.translationTask`. On macOS 14 it is absent (no Apple card).
  - [ ] Add an OpenAI-compatible service in the Translation settings tab with a real base URL + key; on the next ENTER its card streams tokens incrementally (not a single jump). Disabling it removes its card.
  - [ ] Trigger the screenshot-translate hotkey: select a region with on-screen text; the window opens prefilled with the recognized text and auto-translates.
  - [ ] Select text in another app, trigger translate-selection: the window opens prefilled (AX path; if AX yields nothing the clipboard-copy fallback runs and the original pasteboard is restored).
  - [ ] Pin the panel (it stays visible when focus leaves). Copy buttons copy each card's text. TTS speaker buttons speak.
  - [ ] Toggle Auto-speak on; the next successful translation speaks automatically.
  - [ ] Favorite a result and confirm it shows in favorites; recent history accumulates and survives an app relaunch (SwiftData persistence). "清空历史" empties it.
  - [ ] Export config (Settings → General → backup), wipe the translation settings, import: target/second-target/auto-speak/services come back and apply without relaunch (verify a service you added reappears, minus its Keychain key, which is excluded by design).

- [ ] **Step 6: Closing gate — full build + full test suite.**

```bash
swift build && swift test
```

Expected result: the build succeeds and the entire test suite passes (including the new `SyncSettingsRegistryTranslationTests` plus every translation unit test from prior phases — providers/parsing, settings, keychain, detection, coordinator, history). Fix any regression before committing.

- [ ] **Step 7: Commit.**

```bash
git add -A && git commit -m "chore(translation): finalize integration wiring and verify end-to-end"
```

---
