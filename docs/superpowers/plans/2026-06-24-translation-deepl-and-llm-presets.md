# DeepL Backend + LLM Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a DeepL (official + DeepLX) translation backend and a one-click "add by provider" preset catalog for the common LLM services, so the panel covers a dedicated MT API and key-only LLM setup.

**Architecture:** A new `deepl` provider kind (one-shot JSON, like Google/Bing) selected official-vs-DeepLX by `baseURL`, with code mapping in a pure `DeepLLanguage` helper. A static `TranslationServicePreset.catalog` pre-fills a new service's connection fields. A new optional `extraBodyJSON` on the OpenAI-compatible config (Codable, not SwiftData → no migration) lets presets disable a model's thinking mode. The add-service button becomes a preset menu; the editor sheet becomes kind-aware.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, URLSession, JSONSerialization, XCTest, `.xcstrings` string catalog.

## Global Constraints

- Swift 6.2, strict concurrency (`.swiftLanguageMode(.v6)`); macOS 14+.
- All code comments in English. All commit messages in English, Conventional Commits (`type(scope): subject`, lowercase, imperative, ≤72 chars).
- NO `Co-Authored-By` trailers; NO AI/tool watermark lines. Strip any `@` from commit text.
- UI-facing strings stay Chinese; every new user-facing string added to BOTH `L10n.Key` (Sources/AnyDoor/Utilities/L10n.swift) AND `Localizable.xcstrings` (Sources/AnyDoor/Resources/Localizable.xcstrings) or the build-tool plugin fails.
- Providers throw `TranslationProviderError`; never call `L(...)` inside a (nonisolated) provider — the coordinator renders messages.
- Build with `swift build`; run tests with `swift test`. Commit per task locally. **Do NOT push.**
- Spec: `docs/superpowers/specs/2026-06-24-translation-deepl-and-llm-presets-design.md`.

---

### Task 1: Add the `deepl` service kind

**Files:**
- Modify: `Sources/AnyDoor/Models/Translation/TranslationServiceKind.swift`
- Modify: `Sources/AnyDoor/Models/Translation/TranslationLanguage.swift:26-62` (two switches must stay exhaustive)
- Test: `Tests/AnyDoorTests/TranslationServiceConfigTests.swift:5-17`

**Interfaces:**
- Produces: `TranslationServiceKind.deepl` (rawValue `"deepl"`), consumed by Tasks 3, 4, 7, 9.

- [ ] **Step 1: Update the failing test for case coverage**

In `TranslationServiceConfigTests.swift`, change `testServiceKindCaseCoverage` and add a raw-value assertion:

```swift
func testServiceKindCaseCoverage() {
    XCTAssertEqual(
        Set(TranslationServiceKind.allCases),
        [.apple, .googleFree, .bingFree, .openAICompatible, .deepl]
    )
}

func testDeepLRawValueIsStable() {
    XCTAssertEqual(TranslationServiceKind.deepl.rawValue, "deepl")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TranslationServiceConfigTests`
Expected: FAIL (compile error: `.deepl` not a member of `TranslationServiceKind`).

- [ ] **Step 3: Add the enum case**

In `TranslationServiceKind.swift`, add `case deepl` to the enum:

```swift
enum TranslationServiceKind: String, Codable, Sendable, CaseIterable {
    case apple
    case googleFree
    case bingFree
    case openAICompatible
    case deepl
}
```

- [ ] **Step 4: Keep `TranslationLanguage` switches exhaustive**

In `TranslationLanguage.swift`, add `.deepl` to the pass-through groups of both `serviceCode(for:)` and `fromServiceCode(_:for:)` (DeepL maps via `DeepLLanguage`, not here, so a pass-through keeps the switch exhaustive without affecting behavior):

```swift
    func serviceCode(for kind: TranslationServiceKind) -> String {
        switch kind {
        case .googleFree, .bingFree:
            return Self.serviceCodeRemap[code] ?? code
        // DeepL remaps via DeepLLanguage, not here; pass through to stay exhaustive.
        case .apple, .openAICompatible, .deepl:
            return code
        }
    }
```

```swift
    static func fromServiceCode(_ code: String, for kind: TranslationServiceKind) -> TranslationLanguage? {
        switch kind {
        case .googleFree, .bingFree:
            let canonical = serviceCodeReverseRemap[code] ?? code
            return named(canonical)
        case .apple, .openAICompatible, .deepl:
            return named(code)
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter TranslationServiceConfigTests`
Expected: PASS. Also run `swift build` to confirm both switches compile.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Models/Translation/TranslationServiceKind.swift Sources/AnyDoor/Models/Translation/TranslationLanguage.swift Tests/AnyDoorTests/TranslationServiceConfigTests.swift
git commit -m "feat(translation): add deepl service kind"
```

---

### Task 2: `DeepLLanguage` code mapping (pure)

**Files:**
- Create: `Sources/AnyDoor/Services/Translation/DeepLLanguage.swift`
- Test: `Tests/AnyDoorTests/DeepLLanguageTests.swift`

**Interfaces:**
- Produces (consumed by Task 3):
  - `DeepLLanguage.targetCode(_ lang: TranslationLanguage, deeplx: Bool) -> String`
  - `DeepLLanguage.sourceCode(_ lang: TranslationLanguage?, deeplx: Bool) -> String?`
  - `DeepLLanguage.language(fromDetected code: String) -> TranslationLanguage?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnyDoorTests/DeepLLanguageTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class DeepLLanguageTests: XCTestCase {
    func testOfficialTargetUsesVariantCodes() {
        XCTAssertEqual(DeepLLanguage.targetCode(.simplifiedChinese, deeplx: false), "ZH-HANS")
        XCTAssertEqual(DeepLLanguage.targetCode(.english, deeplx: false), "EN-US")
        let hant = TranslationLanguage.named("zh-Hant")!
        XCTAssertEqual(DeepLLanguage.targetCode(hant, deeplx: false), "ZH-HANT")
        let pt = TranslationLanguage.named("pt")!
        XCTAssertEqual(DeepLLanguage.targetCode(pt, deeplx: false), "PT-PT")
        let ja = TranslationLanguage.named("ja")!
        XCTAssertEqual(DeepLLanguage.targetCode(ja, deeplx: false), "JA")
    }

    func testDeepLXTargetUsesBaseCodes() {
        XCTAssertEqual(DeepLLanguage.targetCode(.simplifiedChinese, deeplx: true), "ZH")
        XCTAssertEqual(DeepLLanguage.targetCode(.english, deeplx: true), "EN")
        let pt = TranslationLanguage.named("pt")!
        XCTAssertEqual(DeepLLanguage.targetCode(pt, deeplx: true), "PT")
    }

    func testSourceUsesBaseCodesAndNilHandling() {
        XCTAssertEqual(DeepLLanguage.sourceCode(.simplifiedChinese, deeplx: false), "ZH")
        XCTAssertEqual(DeepLLanguage.sourceCode(.english, deeplx: false), "EN")
        XCTAssertNil(DeepLLanguage.sourceCode(nil, deeplx: false))
        XCTAssertEqual(DeepLLanguage.sourceCode(nil, deeplx: true), "auto")
    }

    func testLanguageFromDetected() {
        XCTAssertEqual(DeepLLanguage.language(fromDetected: "EN"), .english)
        XCTAssertEqual(DeepLLanguage.language(fromDetected: "ZH"), .simplifiedChinese)
        XCTAssertEqual(DeepLLanguage.language(fromDetected: "JA"), TranslationLanguage.named("ja"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DeepLLanguageTests`
Expected: FAIL (`DeepLLanguage` undefined).

- [ ] **Step 3: Implement `DeepLLanguage`**

Create `Sources/AnyDoor/Services/Translation/DeepLLanguage.swift`:

```swift
import Foundation

/// DeepL language-code mapping, kept pure so it can be unit-tested without a
/// network or UI. DeepL's source side uses variant-agnostic base codes (`ZH`,
/// `EN`) while its target side prefers variant codes (`ZH-HANS`, `EN-US`); the
/// unofficial DeepLX proxy mirrors the older API and wants base codes for both.
/// The dictionary is keyed explicitly by every `TranslationLanguage.catalog`
/// code so regional-variant languages are pinned, never gambled.
enum DeepLLanguage {
    /// Official DeepL `target_lang` per catalog code. Variant-sensitive languages
    /// (`en`, `zh-*`, `pt`) are pinned; the rest are their uppercased base, listed
    /// so a reviewer can audit every language rather than trusting a fallback.
    private static let officialTarget: [String: String] = [
        "en": "EN-US", "zh-Hans": "ZH-HANS", "zh-Hant": "ZH-HANT",
        "ja": "JA", "ko": "KO", "fr": "FR", "de": "DE", "es": "ES",
        "pt": "PT-PT", "it": "IT", "ru": "RU", "ar": "AR", "hi": "HI",
        "th": "TH", "vi": "VI", "id": "ID", "tr": "TR", "nl": "NL",
        "pl": "PL", "uk": "UK", "sv": "SV", "cs": "CS", "el": "EL",
        "he": "HE", "ro": "RO", "da": "DA", "fi": "FI",
    ]

    /// `target_lang` for a translation. DeepLX wants base codes (`ZH`, `EN`, `PT`)
    /// where official prefers variants.
    static func targetCode(_ lang: TranslationLanguage, deeplx: Bool) -> String {
        if deeplx {
            switch lang.code {
            case "en": return "EN"
            case "zh-Hans", "zh-Hant": return "ZH"
            case "pt": return "PT"
            default: return officialTarget[lang.code] ?? lang.code.uppercased()
            }
        }
        return officialTarget[lang.code] ?? lang.code.uppercased()
    }

    /// `source_lang` for a translation — always a base code. Returns nil to omit
    /// for auto-detect (official) or "auto" (DeepLX, which wants an explicit value).
    static func sourceCode(_ lang: TranslationLanguage?, deeplx: Bool) -> String? {
        guard let lang else { return deeplx ? "auto" : nil }
        switch lang.code {
        case "zh-Hans", "zh-Hant": return "ZH"
        default:
            let base = lang.code.split(separator: "-").first.map(String.init) ?? lang.code
            return base.uppercased()
        }
    }

    /// Resolves a DeepL detected-source code (e.g. "EN", "ZH", "JA") back to a
    /// catalog language. DeepL detection does not distinguish Hans/Hant, so "ZH"
    /// defaults to Simplified.
    static func language(fromDetected code: String) -> TranslationLanguage? {
        let upper = code.uppercased()
        if upper.hasPrefix("ZH") { return .simplifiedChinese }
        if upper.hasPrefix("EN") { return .english }
        return TranslationLanguage.named(code.lowercased())
            ?? TranslationLanguage.named(String(code.prefix(2)).lowercased())
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter DeepLLanguageTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Translation/DeepLLanguage.swift Tests/AnyDoorTests/DeepLLanguageTests.swift
git commit -m "feat(translation): add pure DeepL language-code mapping"
```

---

### Task 3: `DeepLProvider`

**Files:**
- Create: `Sources/AnyDoor/Services/Translation/DeepLProvider.swift`
- Test: `Tests/AnyDoorTests/DeepLProviderTests.swift`

**Interfaces:**
- Consumes: `TranslationServiceConfig`, `TranslationRequest`, `TranslationChunk`, `TranslationProviderError`, `DeepLLanguage` (Task 2), `MockURLProtocol` (existing test helper).
- Produces (consumed by Task 4): `DeepLProvider(config: TranslationServiceConfig, apiKey: String, session: URLSession = .shared)` conforming to `TranslationProvider` with `kind == .deepl`; static helpers `officialHost(forKey:)`, `buildOfficialRequest(apiKey:text:source:target:)`, `buildDeepLXRequest(baseURL:token:text:source:target:)`, `normalizeDeepLXBase(_:)`, `parseOfficial(_:)`, `parseDeepLX(_:)`, `parseErrorMessage(_:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnyDoorTests/DeepLProviderTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class DeepLProviderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.responder = nil
        super.tearDown()
    }

    private func config(baseURL: String?) -> TranslationServiceConfig {
        TranslationServiceConfig(
            id: "deepl", kind: .deepl, displayName: "DeepL", iconName: "character.book.closed",
            enabled: true, order: 0, baseURL: baseURL, model: nil, promptTemplate: nil)
    }

    // MARK: - host + request construction

    func testOfficialHostSelectedByFXSuffix() {
        XCTAssertEqual(DeepLProvider.officialHost(forKey: "abc:fx"), "https://api-free.deepl.com")
        XCTAssertEqual(DeepLProvider.officialHost(forKey: "abc"), "https://api.deepl.com")
    }

    func testBuildOfficialRequest() throws {
        let req = try DeepLProvider.buildOfficialRequest(
            apiKey: "key:fx", text: "hello", source: "EN", target: "ZH-HANS")
        XCTAssertEqual(req.url?.absoluteString, "https://api-free.deepl.com/v2/translate")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "DeepL-Auth-Key key:fx")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(json["text"] as? [String], ["hello"])
        XCTAssertEqual(json["target_lang"] as? String, "ZH-HANS")
        XCTAssertEqual(json["source_lang"] as? String, "EN")
    }

    func testBuildOfficialRequestOmitsSourceWhenNil() throws {
        let req = try DeepLProvider.buildOfficialRequest(
            apiKey: "key", text: "hi", source: nil, target: "EN-US")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertNil(json["source_lang"])
    }

    func testNormalizeDeepLXBase() {
        XCTAssertEqual(DeepLProvider.normalizeDeepLXBase("http://x:1188/"), "http://x:1188")
        XCTAssertEqual(DeepLProvider.normalizeDeepLXBase("http://x:1188/translate"), "http://x:1188")
        XCTAssertEqual(DeepLProvider.normalizeDeepLXBase("  http://x:1188/translate/  "), "http://x:1188")
    }

    func testBuildDeepLXRequestStringBodyAndBearer() throws {
        let req = try DeepLProvider.buildDeepLXRequest(
            baseURL: "http://x:1188/translate", token: "tok", text: "hello", source: "auto", target: "ZH")
        XCTAssertEqual(req.url?.absoluteString, "http://x:1188/translate")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "hello")
        XCTAssertEqual(json["source_lang"] as? String, "auto")
        XCTAssertEqual(json["target_lang"] as? String, "ZH")
    }

    func testBuildDeepLXRequestNoAuthWhenTokenEmpty() throws {
        let req = try DeepLProvider.buildDeepLXRequest(
            baseURL: "http://x:1188", token: "", text: "hi", source: "auto", target: "EN")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: - response parsing

    func testParseOfficial() throws {
        let data = Data(#"{"translations":[{"detected_source_language":"EN","text":"你好"}]}"#.utf8)
        let r = try DeepLProvider.parseOfficial(data)
        XCTAssertEqual(r.text, "你好")
        XCTAssertEqual(r.detectedCode, "EN")
    }

    func testParseDeepLX() throws {
        let data = Data(#"{"code":200,"data":"你好","source_lang":"EN","target_lang":"ZH"}"#.utf8)
        let r = try DeepLProvider.parseDeepLX(data)
        XCTAssertEqual(r.code, 200)
        XCTAssertEqual(r.text, "你好")
        XCTAssertEqual(r.detectedCode, "EN")
    }

    // MARK: - translate() over a mocked session

    private func mock(_ config: TranslationServiceConfig, key: String) -> DeepLProvider {
        DeepLProvider(config: config, apiKey: key, session: MockURLProtocol.session())
    }

    private func collect(_ stream: AsyncThrowingStream<TranslationChunk, Error>) async throws
        -> (detected: TranslationLanguage?, final: String?) {
        var detected: TranslationLanguage?
        var finalText: String?
        for try await chunk in stream {
            switch chunk {
            case .detected(let l): detected = l
            case .final(let s): finalText = s
            case .delta: break
            }
        }
        return (detected, finalText)
    }

    private func firstError(_ stream: AsyncThrowingStream<TranslationChunk, Error>) async -> TranslationProviderError? {
        do { for try await _ in stream {}; return nil }
        catch let e as TranslationProviderError { return e }
        catch { return nil }
    }

    func testOfficialTranslateYieldsDetectedAndFinal() async throws {
        MockURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"translations":[{"detected_source_language":"EN","text":"你好"}]}"#.utf8))
        }
        let request = TranslationRequest(text: "hello", source: .english, target: .simplifiedChinese)
        let r = try await collect(mock(config(baseURL: nil), key: "key:fx").translate(request))
        XCTAssertEqual(r.detected, .english)
        XCTAssertEqual(r.final, "你好")
    }

    func testOfficialMissingKeyReportsMissingAPIKey() async {
        let request = TranslationRequest(text: "hello", source: nil, target: .simplifiedChinese)
        let error = await firstError(mock(config(baseURL: nil), key: "").translate(request))
        XCTAssertEqual(error, .missingAPIKey)
    }

    func testOfficial403SurfacesMessage() async {
        MockURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"message":"Authorization failure"}"#.utf8))
        }
        let request = TranslationRequest(text: "hello", source: nil, target: .simplifiedChinese)
        let error = await firstError(mock(config(baseURL: nil), key: "key").translate(request))
        XCTAssertEqual(error, .apiError(status: 403, message: "Authorization failure"))
    }

    func testDeepLXTranslateReadsData() async throws {
        MockURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"code":200,"data":"你好","source_lang":"EN","target_lang":"ZH"}"#.utf8))
        }
        let request = TranslationRequest(text: "hello", source: nil, target: .simplifiedChinese)
        let r = try await collect(mock(config(baseURL: "http://x:1188"), key: "").translate(request))
        XCTAssertEqual(r.detected, .english)
        XCTAssertEqual(r.final, "你好")
    }

    func testDeepLXNon200JSONCodeIsError() async {
        MockURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"code":429,"data":"","message":"Too many requests"}"#.utf8))
        }
        let request = TranslationRequest(text: "hello", source: nil, target: .simplifiedChinese)
        let error = await firstError(mock(config(baseURL: "http://x:1188"), key: "").translate(request))
        XCTAssertEqual(error, .apiError(status: 429, message: "Too many requests"))
    }

    func testEmptyInputReportsEmptyInput() async {
        let request = TranslationRequest(text: "   ", source: nil, target: .simplifiedChinese)
        let error = await firstError(mock(config(baseURL: nil), key: "key").translate(request))
        XCTAssertEqual(error, .emptyInput)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DeepLProviderTests`
Expected: FAIL (`DeepLProvider` undefined).

- [ ] **Step 3: Implement `DeepLProvider`**

Create `Sources/AnyDoor/Services/Translation/DeepLProvider.swift`:

```swift
import Foundation

/// DeepL backend. One-shot JSON (no streaming): performs a single POST then
/// yields a `.detected` chunk (mapped source) and a single `.final` chunk, or
/// finishes throwing. `config.baseURL` selects the mode — empty/nil uses the
/// official DeepL API (host chosen by the key's `:fx` suffix); a non-empty value
/// targets a user-hosted DeepLX proxy. The secret in `apiKey` is the DeepL
/// auth key (official, required) or the optional DeepLX access token.
struct DeepLProvider: TranslationProvider {
    let id: String
    var kind: TranslationServiceKind { .deepl }

    private let config: TranslationServiceConfig
    private let apiKey: String
    private let session: URLSession

    init(config: TranslationServiceConfig, apiKey: String, session: URLSession = .shared) {
        self.id = config.id
        self.config = config
        self.apiKey = apiKey
        self.session = session
    }

    private var deeplxBase: String? {
        guard let base = config.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !base.isEmpty else { return nil }
        return base
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

                    let isDeepLX = deeplxBase != nil
                    let urlRequest: URLRequest
                    if let base = deeplxBase {
                        urlRequest = try Self.buildDeepLXRequest(
                            baseURL: base,
                            token: apiKey,
                            text: request.text,
                            source: DeepLLanguage.sourceCode(request.source, deeplx: true) ?? "auto",
                            target: DeepLLanguage.targetCode(request.target, deeplx: true))
                    } else {
                        guard !apiKey.isEmpty else {
                            continuation.finish(throwing: TranslationProviderError.missingAPIKey)
                            return
                        }
                        urlRequest = try Self.buildOfficialRequest(
                            apiKey: apiKey,
                            text: request.text,
                            source: DeepLLanguage.sourceCode(request.source, deeplx: false),
                            target: DeepLLanguage.targetCode(request.target, deeplx: false))
                    }

                    let (data, response) = try await session.data(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: TranslationProviderError.badResponse(-1))
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        if let message = Self.parseErrorMessage(data) {
                            continuation.finish(throwing: TranslationProviderError.apiError(status: http.statusCode, message: message))
                        } else {
                            continuation.finish(throwing: TranslationProviderError.badResponse(http.statusCode))
                        }
                        return
                    }

                    let parsed: (text: String, detectedCode: String?)
                    if isDeepLX {
                        let r = try Self.parseDeepLX(data)
                        guard r.code == 200 else {
                            if let message = Self.parseErrorMessage(data) {
                                continuation.finish(throwing: TranslationProviderError.apiError(status: r.code, message: message))
                            } else {
                                continuation.finish(throwing: TranslationProviderError.badResponse(r.code))
                            }
                            return
                        }
                        parsed = (r.text, r.detectedCode)
                    } else {
                        parsed = try Self.parseOfficial(data)
                    }

                    if Task.isCancelled { return }
                    guard !parsed.text.isEmpty else {
                        continuation.finish(throwing: TranslationProviderError.emptyResponse)
                        return
                    }
                    if let code = parsed.detectedCode, let lang = DeepLLanguage.language(fromDetected: code) {
                        continuation.yield(.detected(lang))
                    }
                    continuation.yield(.final(parsed.text))
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

    // MARK: - Official

    /// A DeepL API Free key ends in `:fx` and must hit the Free host; everything
    /// else is a Pro key on the Pro host.
    static func officialHost(forKey key: String) -> String {
        key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
    }

    static func buildOfficialRequest(apiKey: String, text: String, source: String?, target: String) throws -> URLRequest {
        guard let url = URL(string: officialHost(forKey: apiKey) + "/v2/translate") else {
            throw TranslationProviderError.network("invalid DeepL endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["text": [text], "target_lang": target]
        if let source { body["source_lang"] = source }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseOfficial(_ data: Data) throws -> (text: String, detectedCode: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = root["translations"] as? [[String: Any]],
              let first = translations.first,
              let text = first["text"] as? String else {
            throw TranslationProviderError.decodeFailed
        }
        return (text, first["detected_source_language"] as? String)
    }

    // MARK: - DeepLX

    /// Trims whitespace and a trailing `/`, and drops a trailing `/translate` so a
    /// user who pasted the full endpoint isn't double-suffixed.
    static func normalizeDeepLXBase(_ baseURL: String) -> String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/translate") { s.removeLast("/translate".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func buildDeepLXRequest(baseURL: String, token: String, text: String, source: String, target: String) throws -> URLRequest {
        guard let url = URL(string: normalizeDeepLXBase(baseURL) + "/translate") else {
            throw TranslationProviderError.network("invalid DeepLX base URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["text": text, "source_lang": source, "target_lang": target]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseDeepLX(_ data: Data) throws -> (text: String, code: Int, detectedCode: String?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? Int else {
            throw TranslationProviderError.decodeFailed
        }
        return (root["data"] as? String ?? "", code, root["source_lang"] as? String)
    }

    // MARK: - Errors

    /// DeepL official and DeepLX both surface a human-readable `message` field on
    /// error bodies; pull it so the user sees the backend's own note.
    static func parseErrorMessage(_ data: Data) -> String? {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? String, !message.isEmpty else { return nil }
        return message
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter DeepLProviderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Translation/DeepLProvider.swift Tests/AnyDoorTests/DeepLProviderTests.swift
git commit -m "feat(translation): add DeepL provider with DeepLX fallback"
```

---

### Task 4: Wire `.deepl` into the provider factory

**Files:**
- Modify: `Sources/AnyDoor/Services/Translation/TranslationProviderFactory.swift:18-36`
- Test: `Tests/AnyDoorTests/TranslationProviderFactoryTests.swift`

**Interfaces:**
- Consumes: `DeepLProvider` (Task 3), `TranslationKeychainStore`, `TranslationServiceConfig.isValidBaseURL`.
- Produces: `makeStreamProvider(for:keychain:session:)` returns a `DeepLProvider` for a configured `.deepl` config; nil when official has no key, or DeepLX base URL is invalid.

- [ ] **Step 1: Write the failing tests**

Append to `TranslationProviderFactoryTests.swift` (inside the class). Note the existing `tearDown` deletes a fixed set of ids; add `"deepl"` and `"deeplx"` to that list first:

```swift
    func testBuildsDeepLOfficialWhenKeyed() {
        let keychain = TranslationKeychainStore(service: keychainService)
        keychain.setAPIKey("dk:fx", for: "deepl")
        let config = makeConfig(id: "deepl", kind: .deepl, order: 0)
        let provider = TranslationProviderFactory.makeStreamProvider(
            for: config, keychain: keychain, session: .shared)
        XCTAssertEqual(provider?.kind, .deepl)
    }

    func testSkipsDeepLOfficialWithoutKey() {
        let keychain = TranslationKeychainStore(service: keychainService)
        let config = makeConfig(id: "deepl", kind: .deepl, order: 0)
        XCTAssertNil(TranslationProviderFactory.makeStreamProvider(
            for: config, keychain: keychain, session: .shared))
    }

    func testBuildsDeepLXWithBaseURLAndNoKey() {
        let keychain = TranslationKeychainStore(service: keychainService)
        let config = makeConfig(id: "deeplx", kind: .deepl, order: 0, baseURL: "http://localhost:1188")
        let provider = TranslationProviderFactory.makeStreamProvider(
            for: config, keychain: keychain, session: .shared)
        XCTAssertEqual(provider?.kind, .deepl)
    }

    func testSkipsDeepLXWithInvalidBaseURL() {
        let keychain = TranslationKeychainStore(service: keychainService)
        let config = makeConfig(id: "deeplx", kind: .deepl, order: 0, baseURL: "not-a-url")
        XCTAssertNil(TranslationProviderFactory.makeStreamProvider(
            for: config, keychain: keychain, session: .shared))
    }
```

Also add to the existing `tearDown` body:

```swift
        keychain.deleteAPIKey(for: "deepl")
        keychain.deleteAPIKey(for: "deeplx")
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TranslationProviderFactoryTests`
Expected: FAIL (compile error: `.deepl` not handled / switch needs a case).

- [ ] **Step 3: Add the `.deepl` branch**

In `TranslationProviderFactory.makeStreamProvider`, add a `case .deepl` to the switch (before `.openAICompatible` is fine):

```swift
        case .deepl:
            let key = keychain.apiKey(for: config.id) ?? ""
            if let baseURL = config.baseURL, !baseURL.isEmpty {
                // DeepLX: a valid self-host base URL is enough; the token is optional.
                guard TranslationServiceConfig.isValidBaseURL(baseURL) else { return nil }
                return DeepLProvider(config: config, apiKey: key, session: session)
            }
            // Official DeepL needs an auth key; skip silently when absent (mirrors
            // the openAICompatible "incomplete -> skip" behavior).
            guard !key.isEmpty else { return nil }
            return DeepLProvider(config: config, apiKey: key, session: session)
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter TranslationProviderFactoryTests`
Expected: PASS. Run `swift build` to confirm the switch is exhaustive.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Translation/TranslationProviderFactory.swift Tests/AnyDoorTests/TranslationProviderFactoryTests.swift
git commit -m "feat(translation): build DeepL provider from the factory"
```

---

### Task 5: `extraBodyJSON` + validation helpers on the config

**Files:**
- Modify: `Sources/AnyDoor/Models/Translation/TranslationServiceConfig.swift`
- Test: `Tests/AnyDoorTests/TranslationServiceConfigTests.swift`

**Interfaces:**
- Produces (consumed by Tasks 6, 7, 9):
  - `TranslationServiceConfig.extraBodyJSON: String?` (optional → legacy JSON decodes to nil; implicit nil default in the memberwise init, so existing call sites compile unchanged)
  - `static func isValidExtraBody(_ json: String?) -> Bool`
  - `static func parseExtraBodyObject(_ json: String?) -> [String: Any]?`

- [ ] **Step 1: Write the failing tests**

Append to `TranslationServiceConfigTests.swift`:

```swift
    // MARK: - extraBodyJSON

    func testExtraBodyJSONCodableRoundTripAndLegacyDecodesNil() throws {
        var config = TranslationServiceConfig(
            id: "llm", kind: .openAICompatible, displayName: "L", iconName: "brain",
            enabled: true, order: 0, baseURL: "https://a.com/v1", model: "m", promptTemplate: nil)
        config.extraBodyJSON = #"{"thinking":{"type":"disabled"}}"#
        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(TranslationServiceConfig.self, from: data), config)

        let legacy = #"{"id":"old","kind":"openAICompatible","displayName":"O","iconName":"brain","enabled":true,"order":0}"#
        let decoded = try JSONDecoder().decode(TranslationServiceConfig.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.extraBodyJSON)
    }

    func testIsValidExtraBody() {
        XCTAssertTrue(TranslationServiceConfig.isValidExtraBody(nil))
        XCTAssertTrue(TranslationServiceConfig.isValidExtraBody(""))
        XCTAssertTrue(TranslationServiceConfig.isValidExtraBody("   "))
        XCTAssertTrue(TranslationServiceConfig.isValidExtraBody(#"{"thinking":{"type":"disabled"}}"#))
        XCTAssertFalse(TranslationServiceConfig.isValidExtraBody("[1,2,3]"))
        XCTAssertFalse(TranslationServiceConfig.isValidExtraBody("42"))
        XCTAssertFalse(TranslationServiceConfig.isValidExtraBody("{not json"))
    }

    func testParseExtraBodyObject() {
        XCTAssertNil(TranslationServiceConfig.parseExtraBodyObject(nil))
        XCTAssertNil(TranslationServiceConfig.parseExtraBodyObject(""))
        XCTAssertNil(TranslationServiceConfig.parseExtraBodyObject("[1]"))
        let obj = TranslationServiceConfig.parseExtraBodyObject(#"{"a":1}"#)
        XCTAssertEqual(obj?["a"] as? Int, 1)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TranslationServiceConfigTests`
Expected: FAIL (`extraBodyJSON` / `isValidExtraBody` undefined).

- [ ] **Step 3: Add the field and helpers**

In `TranslationServiceConfig.swift`, add the stored property after `manualMode`:

```swift
    var manualMode: Bool?
    /// `openAICompatible` only: extra top-level JSON merged into the request body
    /// (e.g. `{"thinking":{"type":"disabled"}}` to disable a model's thinking
    /// mode). Optional so legacy stored JSON still decodes; the memberwise init
    /// gives it an implicit nil default so existing call sites are unchanged.
    var extraBodyJSON: String?
```

Add the helpers inside the `extension TranslationServiceConfig` (next to `isValidBaseURL`):

```swift
    /// Whether `json` is acceptable as `extraBodyJSON`: empty/whitespace (no extra
    /// body) or a JSON **object**. A JSON array, scalar, or malformed string is
    /// rejected. Backs both the editor's save gate and the runtime merge guard so
    /// the two never diverge.
    static func isValidExtraBody(_ json: String?) -> Bool {
        let trimmed = (json ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) != nil
    }

    /// Parses `extraBodyJSON` into a top-level dictionary, or nil when empty or not
    /// a JSON object.
    static func parseExtraBodyObject(_ json: String?) -> [String: Any]? {
        let trimmed = (json ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return obj
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter TranslationServiceConfigTests`
Expected: PASS. Run `swift build` (confirms all existing `TranslationServiceConfig(...)` call sites still compile with the new optional).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/Translation/TranslationServiceConfig.swift Tests/AnyDoorTests/TranslationServiceConfigTests.swift
git commit -m "feat(translation): add extra-body JSON field to service config"
```

---

### Task 6: Merge `extraBodyJSON` in the OpenAI-compatible request

**Files:**
- Modify: `Sources/AnyDoor/Services/Translation/OpenAICompatibleProvider.swift:48-60,129-147`
- Test: `Tests/AnyDoorTests/OpenAICompatibleProviderTests.swift`

**Interfaces:**
- Consumes: `TranslationServiceConfig.parseExtraBodyObject` (Task 5).
- Produces: `buildRequest(baseURL:model:apiKey:prompt:extraBodyJSON:)` merges the extra body's top-level keys (base keys win on conflict).

- [ ] **Step 1: Write the failing tests**

Append to `OpenAICompatibleProviderTests.swift`:

```swift
    func testBuildRequestMergesExtraBodyTopLevelKeys() throws {
        let request = try OpenAICompatibleProvider.buildRequest(
            baseURL: "https://api.example.com", model: "m", apiKey: "k", prompt: "p",
            extraBodyJSON: #"{"thinking":{"type":"disabled"},"temperature":0.2}"#)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual((json["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual(json["temperature"] as? Double, 0.2)
        // Base keys remain intact.
        XCTAssertEqual(json["model"] as? String, "m")
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testBuildRequestExtraBodyDoesNotOverrideBaseKeys() throws {
        let request = try OpenAICompatibleProvider.buildRequest(
            baseURL: "https://api.example.com", model: "real", apiKey: "k", prompt: "p",
            extraBodyJSON: #"{"model":"evil","stream":false}"#)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "real")
        XCTAssertEqual(json["stream"] as? Bool, true)
    }

    func testBuildRequestIgnoresInvalidExtraBody() throws {
        let request = try OpenAICompatibleProvider.buildRequest(
            baseURL: "https://api.example.com", model: "m", apiKey: "k", prompt: "p",
            extraBodyJSON: "[not an object]")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        // Degrades to the plain request: only the three base keys.
        XCTAssertEqual(Set(json.keys), ["model", "stream", "messages"])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter OpenAICompatibleProviderTests`
Expected: FAIL (compile error: `buildRequest` has no `extraBodyJSON:` parameter).

- [ ] **Step 3: Add the parameter and merge**

In `OpenAICompatibleProvider.swift`, change the `buildRequest` call inside `translate(...)` to pass the config's value:

```swift
                    let urlRequest = try Self.buildRequest(
                        baseURL: baseURL,
                        model: model,
                        apiKey: apiKey,
                        prompt: prompt,
                        extraBodyJSON: config.extraBodyJSON
                    )
```

Then update the static `buildRequest` signature and body:

```swift
    static func buildRequest(baseURL: String, model: String, apiKey: String, prompt: String, extraBodyJSON: String? = nil) throws -> URLRequest {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBase = trimmedBase.hasSuffix("/") ? String(trimmedBase.dropLast()) : trimmedBase
        guard !normalizedBase.isEmpty, let url = URL(string: normalizedBase + "/chat/completions") else {
            throw TranslationProviderError.network("invalid base URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [["role": "user", "content": prompt]],
        ]
        // Merge any preset/user extra options (e.g. thinking-disable). Base keys
        // win, so a stray "model"/"stream"/"messages" in the extra body can't
        // hijack the request.
        if let extra = TranslationServiceConfig.parseExtraBodyObject(extraBodyJSON) {
            for (key, value) in extra where body[key] == nil {
                body[key] = value
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter OpenAICompatibleProviderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Translation/OpenAICompatibleProvider.swift Tests/AnyDoorTests/OpenAICompatibleProviderTests.swift
git commit -m "feat(translation): merge extra-body JSON into LLM requests"
```

---

### Task 7: `TranslationServicePreset` catalog + draft builder

**Files:**
- Create: `Sources/AnyDoor/Models/Translation/TranslationServicePreset.swift`
- Test: `Tests/AnyDoorTests/TranslationServicePresetTests.swift`

**Interfaces:**
- Consumes: `TranslationServiceConfig`, `TranslationServiceKind`.
- Produces (consumed by Tasks 9, 10):
  - `TranslationServicePreset.catalog: [TranslationServicePreset]`
  - `func makeDraft(order: Int, id: String) -> (config: TranslationServiceConfig, apiKey: String)`
  - properties: `id, displayName, iconName, kind, baseURL?, model?, promptTemplate?, extraBodyJSON?, defaultAPIKey?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnyDoorTests/TranslationServicePresetTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class TranslationServicePresetTests: XCTestCase {
    func testCatalogHasUniqueIDsAndStartsWithDeepL() {
        let catalog = TranslationServicePreset.catalog
        XCTAssertEqual(catalog.first?.id, "deepl")
        XCTAssertEqual(catalog.first?.kind, .deepl)
        XCTAssertEqual(Set(catalog.map(\.id)).count, catalog.count)
        XCTAssertEqual(catalog.last?.id, "custom")
    }

    func testLLMPresetsCarryBaseURLAndModel() {
        // Every openAICompatible preset except the blank "custom" sentinel must
        // carry a base URL + model so it is runnable after just a key.
        for preset in TranslationServicePreset.catalog
        where preset.kind == .openAICompatible && preset.id != "custom" {
            XCTAssertFalse(preset.baseURL?.isEmpty ?? true, "\(preset.id) missing baseURL")
            XCTAssertFalse(preset.model?.isEmpty ?? true, "\(preset.id) missing model")
        }
    }

    func testDeepSeekPresetDisablesThinking() {
        let deepseek = TranslationServicePreset.catalog.first { $0.id == "deepseek" }
        XCTAssertEqual(deepseek?.model, "deepseek-v4-flash")
        XCTAssertTrue(TranslationServiceConfig.isValidExtraBody(deepseek?.extraBodyJSON))
        XCTAssertNotNil(deepseek?.extraBodyJSON)
    }

    func testOllamaPresetPrefillsKey() {
        let ollama = TranslationServicePreset.catalog.first { $0.id == "ollama" }
        XCTAssertEqual(ollama?.defaultAPIKey, "ollama")
    }

    func testMakeDraftAssignsIDOrderAndKey() {
        let ollama = TranslationServicePreset.catalog.first { $0.id == "ollama" }!
        let (config, key) = ollama.makeDraft(order: 5, id: "fixed-id")
        XCTAssertEqual(config.id, "fixed-id")
        XCTAssertEqual(config.order, 5)
        XCTAssertEqual(config.kind, .openAICompatible)
        XCTAssertEqual(config.baseURL, "http://localhost:11434/v1/")
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(key, "ollama")
    }

    func testMakeDraftDeepLHasNoModelOrKey() {
        let deepl = TranslationServicePreset.catalog.first { $0.id == "deepl" }!
        let (config, key) = deepl.makeDraft(order: 0, id: "x")
        XCTAssertEqual(config.kind, .deepl)
        XCTAssertNil(config.baseURL)
        XCTAssertNil(config.model)
        XCTAssertEqual(key, "")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TranslationServicePresetTests`
Expected: FAIL (`TranslationServicePreset` undefined).

- [ ] **Step 3: Implement the preset catalog**

Create `Sources/AnyDoor/Models/Translation/TranslationServicePreset.swift`:

```swift
import Foundation

/// A one-click "add by provider" template. Selecting a preset pre-fills a new
/// `TranslationServiceConfig` so the user only supplies an API key. Pure data +
/// a draft builder; the menu and editor live in the views layer. Brand display
/// names are intentionally not localized; the "custom" sentinel renders its menu
/// label from `L10n` in the view.
struct TranslationServicePreset: Identifiable, Sendable {
    let id: String
    let displayName: String
    let iconName: String
    let kind: TranslationServiceKind
    let baseURL: String?
    let model: String?
    let promptTemplate: String?
    let extraBodyJSON: String?
    let defaultAPIKey: String?

    /// Builds a fresh draft config from this preset. `id` is injected (the view
    /// passes a new UUID) so the builder stays pure and testable. Returns the
    /// config plus the editor's initial key (empty unless the preset pre-fills one).
    func makeDraft(order: Int, id: String) -> (config: TranslationServiceConfig, apiKey: String) {
        let config = TranslationServiceConfig(
            id: id,
            kind: kind,
            displayName: displayName,
            iconName: iconName,
            enabled: true,
            order: order,
            baseURL: baseURL,
            model: model,
            promptTemplate: promptTemplate,
            extraBodyJSON: extraBodyJSON
        )
        return (config, defaultAPIKey ?? "")
    }

    /// DeepL first, then the LLM providers, then a blank custom sentinel. Model
    /// ids/base URLs are the spec's verified values (2026-06).
    static let catalog: [TranslationServicePreset] = [
        TranslationServicePreset(id: "deepl", displayName: "DeepL", iconName: "character.book.closed",
            kind: .deepl, baseURL: nil, model: nil, promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "openai", displayName: "OpenAI", iconName: "brain",
            kind: .openAICompatible, baseURL: "https://api.openai.com/v1", model: "gpt-5.4-mini",
            promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "deepseek", displayName: "DeepSeek", iconName: "brain",
            kind: .openAICompatible, baseURL: "https://api.deepseek.com", model: "deepseek-v4-flash",
            promptTemplate: nil, extraBodyJSON: #"{"thinking":{"type":"disabled"}}"#, defaultAPIKey: nil),
        TranslationServicePreset(id: "dashscope", displayName: "通义千问 Qwen", iconName: "brain",
            kind: .openAICompatible, baseURL: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            model: "qwen-plus", promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "gemini", displayName: "Gemini", iconName: "sparkles",
            kind: .openAICompatible, baseURL: "https://generativelanguage.googleapis.com/v1beta/openai/",
            model: "gemini-3.5-flash", promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "moonshot", displayName: "Kimi", iconName: "brain",
            kind: .openAICompatible, baseURL: "https://api.moonshot.ai/v1", model: "kimi-k2.6",
            promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "zhipu", displayName: "智谱 GLM", iconName: "brain",
            kind: .openAICompatible, baseURL: "https://open.bigmodel.cn/api/paas/v4", model: "glm-4.7-flash",
            promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "openrouter", displayName: "OpenRouter", iconName: "arrow.triangle.branch",
            kind: .openAICompatible, baseURL: "https://openrouter.ai/api/v1", model: "google/gemini-3.5-flash",
            promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
        TranslationServicePreset(id: "ollama", displayName: "Ollama", iconName: "desktopcomputer",
            kind: .openAICompatible, baseURL: "http://localhost:11434/v1/", model: "qwen3:4b",
            promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: "ollama"),
        TranslationServicePreset(id: "custom", displayName: "", iconName: "slider.horizontal.3",
            kind: .openAICompatible, baseURL: nil, model: nil, promptTemplate: nil, extraBodyJSON: nil, defaultAPIKey: nil),
    ]
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter TranslationServicePresetTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/Translation/TranslationServicePreset.swift Tests/AnyDoorTests/TranslationServicePresetTests.swift
git commit -m "feat(translation): add service preset catalog"
```

---

### Task 8: Localization keys for the new UI

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift` (add cases near the other `settingsTranslationService*` cases, ~line 286)
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`

**Interfaces:**
- Produces (consumed by Tasks 9, 10): `L10n.Key` cases `settingsTranslationPresetCustom`, `settingsTranslationServiceExtraBody`, `settingsTranslationServiceExtraBodyHint`, `settingsTranslationServiceExtraBodyInvalid`, `settingsTranslationDeepLAdvanced`, `settingsTranslationDeepLEndpoint`, `settingsTranslationDeepLToken`, `settingsTranslationDeepLHint`.

- [ ] **Step 1: Add the `L10n.Key` cases**

In `L10n.swift`, after `case settingsTranslationServiceManualModeHint` (line ~286) add:

```swift
        case settingsTranslationPresetCustom = "settings.translation.presetCustom"
        case settingsTranslationServiceExtraBody = "settings.translation.serviceExtraBody"
        case settingsTranslationServiceExtraBodyHint = "settings.translation.serviceExtraBodyHint"
        case settingsTranslationServiceExtraBodyInvalid = "settings.translation.serviceExtraBodyInvalid"
        case settingsTranslationDeepLAdvanced = "settings.translation.deepLAdvanced"
        case settingsTranslationDeepLEndpoint = "settings.translation.deepLEndpoint"
        case settingsTranslationDeepLToken = "settings.translation.deepLToken"
        case settingsTranslationDeepLHint = "settings.translation.deepLHint"
```

- [ ] **Step 2: Add the matching `.xcstrings` entries**

Run this script (it round-trips the catalog and inserts the eight entries with en + zh-Hans values):

```bash
python3 - <<'PY'
import json
p = "Sources/AnyDoor/Resources/Localizable.xcstrings"
d = json.load(open(p))
def entry(en, zh):
    return {"extractionState": "manual", "localizations": {
        "en": {"stringUnit": {"state": "translated", "value": en}},
        "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}}}}
add = {
  "settings.translation.presetCustom": ("Custom", "自定义"),
  "settings.translation.serviceExtraBody": ("Extra request body (JSON, optional)", "额外请求参数（JSON，可选）"),
  "settings.translation.serviceExtraBodyHint": ("Extra top-level JSON merged into the request body, e.g. to disable thinking mode.", "合并进请求体的额外 JSON 字段，例如关闭思考模式。"),
  "settings.translation.serviceExtraBodyInvalid": ("Extra parameters must be a valid JSON object.", "额外参数必须是合法的 JSON 对象。"),
  "settings.translation.deepLAdvanced": ("Advanced (DeepLX self-host)", "高级（DeepLX 自建端点）"),
  "settings.translation.deepLEndpoint": ("DeepLX endpoint (optional)", "DeepLX 端点（可选）"),
  "settings.translation.deepLToken": ("Access token (optional)", "访问令牌（可选）"),
  "settings.translation.deepLHint": ("Leave the endpoint empty to use the official DeepL API (free/Pro chosen by your key). Fill it to use your self-hosted DeepLX instead.", "端点留空则使用 DeepL 官方 API（按 Key 自动选择免费/Pro）；填写则改用你自建的 DeepLX 服务。"),
}
for k, (en, zh) in add.items():
    d["strings"][k] = entry(en, zh)
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
open(p, "a").write("\n")
print("added", len(add), "entries; total", len(d["strings"]))
PY
```

- [ ] **Step 3: Verify the catalog still parses and the build compiles the strings**

Run: `swift build`
Expected: "Build complete!" (the `XCStringsCompilerPlugin` compiles the catalog; a malformed catalog or a `L10n.Key` raw value with no entry fails here).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(translation): add localized strings for presets and DeepL editor"
```

---

### Task 9: Kind-aware editor + initial-key plumbing

**Files:**
- Modify: `Sources/AnyDoor/Views/TranslationSettingsView.swift` (`TranslationServiceConfigSheet`, `serviceRow`, `presentEditor`)
- Modify: `Sources/AnyDoor/Views/Translation/TranslationServiceEditorOverlay.swift` (thread `initialKey` through `present` + scrim)

**Interfaces:**
- Consumes: `TranslationServiceConfig.isValidExtraBody` (Task 5), `DeepLProvider` (Task 3), the new `L10n.Key` cases (Task 8).
- Produces: `presentEditor(_:isNew:initialKey:)` (initialKey defaults nil so existing callers compile); a kind-aware `TranslationServiceConfigSheet` accepting `initialKey: String?`.

- [ ] **Step 1: Thread `initialKey` through the overlay**

In `TranslationServiceEditorOverlay.swift`, add `initialKey` to `present(...)` and pass it into the scrim/sheet:

```swift
    func present(
        config: TranslationServiceConfig,
        isNew: Bool,
        initialKey: String? = nil,
        keychain: TranslationKeychainStore,
        onSave: @escaping (TranslationServiceConfig, String?) -> Void
    ) {
```

In the `TranslationServiceEditorScrim` construction inside `present`, pass `initialKey: initialKey`:

```swift
        let root = TranslationServiceEditorScrim(
            config: config,
            isNew: isNew,
            initialKey: initialKey,
            keychain: keychain,
            onSave: { [weak self] saved, apiKey in
                onSave(saved, apiKey)
                self?.dismiss()
            },
            onCancel: { [weak self] in self?.dismiss() }
        )
```

Add the stored property to `TranslationServiceEditorScrim` and forward it:

```swift
private struct TranslationServiceEditorScrim: View {
    let config: TranslationServiceConfig
    let isNew: Bool
    let initialKey: String?
    let keychain: TranslationKeychainStore
    let onSave: (TranslationServiceConfig, String?) -> Void
    let onCancel: () -> Void
```

```swift
                TranslationServiceConfigSheet(
                    config: config,
                    isNew: isNew,
                    initialKey: initialKey,
                    keychain: keychain,
                    onSave: onSave,
                    onCancel: onCancel
                )
```

- [ ] **Step 2: Update `presentEditor` in `TranslationSettingsView`**

```swift
    private func presentEditor(_ config: TranslationServiceConfig, isNew: Bool, initialKey: String? = nil) {
        TranslationServiceEditorOverlay.shared.present(
            config: config,
            isNew: isNew,
            initialKey: initialKey,
            keychain: keychain,
            onSave: applySave
        )
    }
```

- [ ] **Step 3: Make the editor sheet kind-aware**

In `TranslationServiceConfigSheet`, add the `initialKey` init parameter and seed the key from it, then branch the form on `draft.kind`. Replace the `init` and the two field `Section`s:

```swift
    init(
        config: TranslationServiceConfig,
        isNew: Bool,
        initialKey: String? = nil,
        keychain: TranslationKeychainStore,
        onSave: @escaping (TranslationServiceConfig, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: config)
        // A new-from-preset draft seeds its key from the preset (e.g. Ollama);
        // otherwise load any stored key for an existing service.
        _apiKey = State(initialValue: initialKey ?? keychain.apiKey(for: config.id) ?? "")
        self.isNew = isNew
        self.keychain = keychain
        self.onSave = onSave
        self.onCancel = onCancel
    }
```

Replace the first two `Section`s in `body` (the connection fields and the prompt) with a kind switch:

```swift
                if draft.kind == .deepl {
                    deepLSection
                } else {
                    llmConnectionSection
                    llmPromptSection
                    llmExtraBodySection
                    llmManualModeSection
                }
```

Add these computed sections to the struct (the LLM ones reuse today's fields; the prompt/manualMode bodies are unchanged from the current code, just extracted):

```swift
    @ViewBuilder private var llmConnectionSection: some View {
        Section {
            TextField(text: $draft.displayName) { LocalizedText(.settingsTranslationServiceName) }
                .focused($focusedField, equals: .name)
            TextField(text: baseURL) { LocalizedText(.settingsTranslationServiceBaseURL) }
            TextField(text: model) { LocalizedText(.settingsTranslationServiceModel) }
            SecureField(text: $apiKey) { LocalizedText(.settingsTranslationServiceAPIKey) }
        } footer: {
            if !TranslationServiceConfig.isValidBaseURL(draft.baseURL ?? "") {
                LocalizedText(.settingsTranslationServiceBaseURLInvalid)
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var llmPromptSection: some View {
        Section {
            TextEditor(text: promptTemplate)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .frame(height: 120)
        } header: {
            LocalizedText(.settingsTranslationServicePrompt)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(.settingsTranslationServicePromptHint)
                    .font(.caption).foregroundStyle(.secondary)
                if !TranslationServiceConfig.promptContainsText(promptTemplate.wrappedValue) {
                    LocalizedText(.settingsTranslationServicePromptMissingText)
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder private var llmExtraBodySection: some View {
        Section {
            TextField(text: extraBodyJSON, axis: .vertical) {
                LocalizedText(.settingsTranslationServiceExtraBody)
            }
            .lineLimit(2...4)
            .font(.body.monospaced())
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(.settingsTranslationServiceExtraBodyHint)
                    .font(.caption).foregroundStyle(.secondary)
                if !TranslationServiceConfig.isValidExtraBody(draft.extraBodyJSON) {
                    LocalizedText(.settingsTranslationServiceExtraBodyInvalid)
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private var llmManualModeSection: some View {
        Section {
            Toggle(isOn: manualMode) { LocalizedText(.settingsTranslationServiceManualMode) }
        } footer: {
            LocalizedText(.settingsTranslationServiceManualModeHint)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var deepLSection: some View {
        Section {
            TextField(text: $draft.displayName) { LocalizedText(.settingsTranslationServiceName) }
                .focused($focusedField, equals: .name)
            SecureField(text: $apiKey) { LocalizedText(.settingsTranslationServiceAPIKey) }
        }
        Section {
            TextField(text: baseURL) { LocalizedText(.settingsTranslationDeepLEndpoint) }
            SecureField(text: $deeplxToken) { LocalizedText(.settingsTranslationDeepLToken) }
        } header: {
            LocalizedText(.settingsTranslationDeepLAdvanced)
        } footer: {
            LocalizedText(.settingsTranslationDeepLHint)
                .font(.caption).foregroundStyle(.secondary)
        }
    }
```

Add bindings + a `deeplxToken` mirror of `apiKey` for the DeepLX advanced field. Because DeepL stores one secret (official key OR DeepLX token) in the same Keychain slot, the DeepLX token field writes the same `apiKey` state:

```swift
    private var extraBodyJSON: Binding<String> {
        Binding(get: { draft.extraBodyJSON ?? "" },
                set: { draft.extraBodyJSON = $0.isEmpty ? nil : $0 })
    }
    private var deeplxToken: Binding<String> {
        Binding(get: { apiKey }, set: { apiKey = $0 })
    }
```

(Keep the existing `baseURL`, `model`, `promptTemplate`, `manualMode` bindings as-is.)

- [ ] **Step 4: Make `isSaveable` and `runTest` kind-aware**

Replace `isSaveable`:

```swift
    private var isSaveable: Bool {
        let named = !draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty
        let keyPresent = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch draft.kind {
        case .deepl:
            // Official needs a key; DeepLX needs a valid endpoint (token optional).
            let validEndpoint = TranslationServiceConfig.isValidBaseURL(draft.baseURL ?? "")
            return named && (keyPresent || validEndpoint)
        default:
            return named
                && TranslationServiceConfig.isValidBaseURL(draft.baseURL ?? "")
                && !(draft.model ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                && keyPresent
                && TranslationServiceConfig.isValidExtraBody(draft.extraBodyJSON)
        }
    }
```

Replace the provider construction in `runTest` so DeepL is tested with its own provider:

```swift
    private func runTest() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = draft
        testState = .testing
        Task {
            let provider: any TranslationProvider = config.kind == .deepl
                ? DeepLProvider(config: config, apiKey: trimmedKey)
                : OpenAICompatibleProvider(config: config, apiKey: trimmedKey)
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
                testState = .failure(translationErrorMessage(error))
            }
        }
    }
```

(Note: the old `runTest` guarded against an empty key. DeepLX has no key, so the guard is removed; `isSaveable`/the provider already handle an empty secret.)

- [ ] **Step 5: Show Edit/Remove for `.deepl` rows**

In `serviceRow`, change the `if config.kind == .openAICompatible {` guard around the Edit/Remove buttons to also include `.deepl`:

```swift
            if config.kind == .openAICompatible || config.kind == .deepl {
                Button { presentEditor(config, isNew: false) } label: {
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
```

- [ ] **Step 6: Build and smoke-check**

Run: `swift build`
Expected: "Build complete!" Then `swift run AnyDoor`, open Settings → 翻译, edit an LLM service (extra-body field + invalid-JSON red footer appear), and confirm an existing service still saves. (UI is verified manually — no unit test for the view.)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Views/TranslationSettingsView.swift Sources/AnyDoor/Views/Translation/TranslationServiceEditorOverlay.swift
git commit -m "feat(translation): make the service editor DeepL- and extra-body-aware"
```

---

### Task 10: Replace the add button with a preset menu

**Files:**
- Modify: `Sources/AnyDoor/Views/TranslationSettingsView.swift:115-130` (the Add button in `servicesSection`)

**Interfaces:**
- Consumes: `TranslationServicePreset.catalog` + `makeDraft` (Task 7), `presentEditor(_:isNew:initialKey:)` (Task 9), `settingsTranslationPresetCustom` (Task 8).

- [ ] **Step 1: Replace the Add button with a `Menu` over the preset catalog**

In `servicesSection`, replace the existing `Button { ... } label: { Label(...Add Service...) }` block with:

```swift
            Menu {
                ForEach(TranslationServicePreset.catalog) { preset in
                    Button {
                        let (config, key) = preset.makeDraft(
                            order: settings.services.count, id: UUID().uuidString)
                        presentEditor(config, isNew: true, initialKey: key)
                    } label: {
                        Label {
                            Text(preset.displayName.isEmpty ? L(.settingsTranslationPresetCustom) : preset.displayName)
                        } icon: {
                            Image(systemName: preset.iconName)
                        }
                    }
                }
            } label: {
                Label { LocalizedText(.settingsTranslationAddService) } icon: { Image(systemName: "plus") }
            }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: "Build complete!"

- [ ] **Step 3: Smoke-check the full flow**

Run: `swift run AnyDoor`. Settings → 翻译 → "添加服务" now opens a menu (DeepL, OpenAI, DeepSeek, 通义千问 Qwen, Gemini, Kimi, 智谱 GLM, OpenRouter, Ollama, 自定义). Picking:
- **DeepL** → editor shows key + Advanced(DeepLX); enter a DeepL key, Test, Save → a DeepL card joins the fan-out on the next translate.
- **Ollama** → key field pre-filled `ollama`.
- **DeepSeek** → save, then translate, and confirm output is non-empty (thinking disabled).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/TranslationSettingsView.swift
git commit -m "feat(translation): add services from a provider preset menu"
```

---

### Task 11: Full test run + changelog

**Files:**
- Modify: `CHANGELOG.md` (under `## [Unreleased]`)

- [ ] **Step 1: Run the whole suite + build**

Run: `swift test`
Expected: all tests pass (existing + the new DeepL / preset / extra-body tests).
Run: `swift build`
Expected: "Build complete!"

- [ ] **Step 2: Add a changelog entry**

Under `## [Unreleased]` in `CHANGELOG.md`, add a bullet (English, user-facing):

```markdown
### Added
- Translation: DeepL backend (official API + self-hosted DeepLX) and one-click provider presets (OpenAI, DeepSeek, Qwen, Gemini, Kimi, 智谱 GLM, OpenRouter, Ollama) so adding a service only needs an API key. LLM services gained an optional extra request-body field (JSON) for per-model options such as disabling thinking mode.
```

(If an existing translation bullet is already under `## [Unreleased]`, fold this into it instead of adding a second.)

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: note DeepL backend and provider presets in the changelog"
```

---

## Self-Review

**Spec coverage:**
- DeepL provider kind → Tasks 1, 3, 4. DeepLX mode + normalization → Task 3. ✅
- `DeepLLanguage` explicit mapping → Task 2. ✅
- Preset catalog + key seeding → Task 7 (+ defaultAPIKey). ✅
- `extraBodyJSON` (config + merge + shared validator) → Tasks 5, 6. ✅
- Kind-aware editor + extra-body editor-time validation + serviceRow → Task 9. ✅
- Preset add-menu → Task 10. ✅
- Verified constants (DeepSeek bare host, gpt-5.4-mini, gemini-3.5-flash, glm-4.7-flash, OpenRouter google/gemini-3.5-flash, Ollama key) → Task 7 catalog. ✅
- Localization (both L10n + xcstrings) → Task 8. ✅
- Testing per spec (DeepLLanguage, DeepLProvider incl. normalization, preset integrity, isValidExtraBody, buildRequest merge) → Tasks 2, 3, 5, 6, 7. ✅
- Non-goals (Chinese MT APIs, official cloud, Claude native, fallback chain, plugin runtime) → not implemented, as intended. ✅

**Placeholder scan:** No TBD/TODO; every code step shows complete code; UI tasks state manual-verification explicitly (views aren't unit-tested).

**Type consistency:** `makeStreamProvider(for:keychain:session:)`, `DeepLProvider(config:apiKey:session:)`, `buildRequest(...:extraBodyJSON:)`, `makeDraft(order:id:)`, `parseExtraBodyObject(_:)` / `isValidExtraBody(_:)`, and `present(...:initialKey:...)` are used identically across the tasks that define and consume them.
