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
