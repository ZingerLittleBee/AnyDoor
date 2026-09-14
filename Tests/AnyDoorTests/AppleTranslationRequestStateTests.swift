import XCTest
@testable import AnyDoor
#if canImport(Translation)
import Translation
#endif

#if canImport(Translation)
/// Production-seam tests for Apple translate request ownership and
/// `TranslationSession.Configuration` scheduling. Assertions use the SDK type's
/// own `==` and `version` — not a copied mock — so same-pair `invalidate()` is
/// distinguished from a no-op reassignment of an equal pair.
@available(macOS 15, *)
@MainActor
final class AppleTranslationRequestStateTests: XCTestCase {
    private func locale(_ language: TranslationLanguage) -> Locale.Language {
        Locale.Language(identifier: language.code)
    }

    private func freshConfiguration(source: TranslationLanguage?,
                                    target: TranslationLanguage) -> TranslationSession.Configuration {
        TranslationSession.Configuration(
            source: source.map { locale($0) },
            target: locale(target)
        )
    }

    private func arm(_ state: AppleTranslationRequestState,
                     text: String = "cool",
                     source: TranslationLanguage? = nil,
                     target: TranslationLanguage = .english,
                     runID: String = "run-1",
                     runToken: Int = 1) {
        state.beginRequest(
            text: text,
            source: source,
            target: target,
            runID: runID,
            runToken: runToken
        )
    }

    func testFirstRequestAssignsFreshAutoDetectConfiguration() {
        let state = AppleTranslationRequestState()
        XCTAssertNil(state.configuration)
        XCTAssertNil(state.currentRequest)

        arm(state, text: "cool", source: nil, target: .english, runID: "r1", runToken: 1)

        let expected = freshConfiguration(source: nil, target: .english)
        XCTAssertEqual(expected.version, 0)
        XCTAssertEqual(state.configuration, expected)
        XCTAssertEqual(state.configuration?.version, 0)
        XCTAssertNil(state.configuration?.source)
        XCTAssertEqual(state.configuration?.target, locale(.english))

        XCTAssertEqual(state.status, .loading)
        XCTAssertEqual(state.currentRequest?.text, "cool")
        XCTAssertNil(state.currentRequest?.source)
        XCTAssertEqual(state.currentRequest?.target, .english)
        XCTAssertEqual(state.currentRequest?.runID, "r1")
        XCTAssertEqual(state.currentRequest?.runToken, 1)
        XCTAssertEqual(state.currentRequest?.generation, state.generation)
    }

    func testRepeatedSamePairInvalidatesExistingConfiguration() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", source: nil, target: .english, runToken: 1)
        let first = try XCTUnwrap(state.configuration)
        let firstGeneration = state.generation
        let reassigned = freshConfiguration(source: nil, target: .english)

        // Official contract: a second same-pair value is still equal at version 0.
        XCTAssertEqual(first, reassigned)
        XCTAssertEqual(first.version, 0)

        arm(state, text: "cool", source: nil, target: .english, runID: "r2", runToken: 2)
        let second = try XCTUnwrap(state.configuration)

        XCTAssertNotEqual(second, first)
        XCTAssertNotEqual(second, reassigned)
        XCTAssertGreaterThan(second.version, first.version)
        XCTAssertEqual(second.source, first.source)
        XCTAssertEqual(second.target, first.target)
        XCTAssertEqual(state.status, .loading)
        XCTAssertEqual(state.generation, firstGeneration + 1)
        XCTAssertEqual(state.currentRequest?.runToken, 2)
        XCTAssertEqual(state.currentRequest?.text, "cool")
    }

    func testLanguagePairChangeWritesRealConfigurationLanguages() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", source: nil, target: .english, runToken: 1)
        let before = try XCTUnwrap(state.configuration)
        let oldPair = freshConfiguration(source: nil, target: .english)
        XCTAssertEqual(before, oldPair)

        arm(state, text: "cool", source: nil, target: .simplifiedChinese, runID: "r2", runToken: 2)
        let after = try XCTUnwrap(state.configuration)
        let newPair = freshConfiguration(source: nil, target: .simplifiedChinese)

        XCTAssertNotEqual(after, before)
        XCTAssertNotEqual(after, oldPair)
        XCTAssertEqual(after, newPair)
        XCTAssertNil(after.source)
        XCTAssertEqual(after.target, locale(.simplifiedChinese))
        XCTAssertEqual(state.currentRequest?.target, .simplifiedChinese)
        XCTAssertNil(state.currentRequest?.source)
    }

    func testExplicitSourceChangeIsARealConfigurationChange() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "hello", source: nil, target: .simplifiedChinese, runToken: 1)
        let before = try XCTUnwrap(state.configuration)

        arm(state, text: "hello", source: .english, target: .simplifiedChinese, runToken: 2)
        let after = try XCTUnwrap(state.configuration)

        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after.source, locale(.english))
        XCTAssertEqual(after.target, locale(.simplifiedChinese))
        XCTAssertEqual(after, freshConfiguration(source: .english, target: .simplifiedChinese))
        XCTAssertEqual(state.currentRequest?.source, .english)
    }

    func testRequestSnapshotStaysImmutableAcrossANewerRequest() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", source: nil, target: .english, runID: "old", runToken: 1)
        let snapshot = try XCTUnwrap(state.currentRequest)

        arm(state, text: "hello world", source: .english, target: .simplifiedChinese, runID: "new", runToken: 2)

        XCTAssertEqual(snapshot.text, "cool")
        XCTAssertNil(snapshot.source)
        XCTAssertEqual(snapshot.target, .english)
        XCTAssertEqual(snapshot.runID, "old")
        XCTAssertEqual(snapshot.runToken, 1)
        XCTAssertEqual(state.currentRequest?.text, "hello world")
        XCTAssertEqual(state.currentRequest?.source, .english)
        XCTAssertEqual(state.currentRequest?.runToken, 2)
        XCTAssertNotEqual(snapshot.generation, state.currentRequest?.generation)
    }

    func testSupersededSuccessDoesNotPublishOrReplaceNewerLoading() {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let oldGeneration = state.generation
        arm(state, text: "cool", runToken: 2)

        XCTAssertEqual(state.apply(.success("旧"), generation: oldGeneration), .ignored)
        XCTAssertEqual(state.status, .loading)
        XCTAssertTrue(state.output.isEmpty)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.currentRequest?.runToken, 2)

        XCTAssertEqual(state.apply(.success("新"), generation: state.generation), .publishedSuccess)
        XCTAssertEqual(state.status, .success)
        XCTAssertEqual(state.output, "新")
    }

    func testSupersededFailureDoesNotPublishIntoNewerRequest() {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let oldGeneration = state.generation
        arm(state, text: "cool", runToken: 2)

        XCTAssertEqual(state.apply(.failureMessage("stale"), generation: oldGeneration), .ignored)
        XCTAssertEqual(state.status, .loading)
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.output.isEmpty)

        XCTAssertEqual(state.apply(.failureMessage("fresh"), generation: state.generation), .publishedFailure)
        XCTAssertEqual(state.status, .failure)
        XCTAssertEqual(state.errorMessage, "fresh")
    }

    func testCancellationNeverSettlesEvenForOwningGeneration() {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let owner = state.generation
        arm(state, text: "cool", runToken: 2)

        XCTAssertEqual(state.apply(.cancelled, generation: owner), .ignored)
        XCTAssertEqual(state.status, .loading)

        XCTAssertEqual(state.apply(.cancelled, generation: state.generation), .ignored)
        XCTAssertEqual(state.status, .loading)
        XCTAssertTrue(state.output.isEmpty)
        XCTAssertNil(state.errorMessage)
    }

    func testOwningUserCancelledResetsOnlyThatGeneration() {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let oldGeneration = state.generation
        arm(state, text: "cool", runToken: 2)

        XCTAssertEqual(state.apply(.userCancelled, generation: oldGeneration), .ignored)
        XCTAssertEqual(state.status, .loading)

        XCTAssertEqual(state.apply(.userCancelled, generation: state.generation), .resetToIdle)
        XCTAssertEqual(state.status, .idle)
        XCTAssertTrue(state.output.isEmpty)
    }

    func testEmptyInputClearsConfigurationAndIgnoresStaleSuccess() {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let oldGeneration = state.generation
        XCTAssertNotNil(state.configuration)

        state.clearArmedTranslation()

        XCTAssertNil(state.configuration)
        XCTAssertNil(state.currentRequest)
        XCTAssertEqual(state.status, .idle)
        XCTAssertGreaterThan(state.generation, oldGeneration)
        XCTAssertEqual(state.apply(.success("迟到"), generation: oldGeneration), .ignored)
        XCTAssertEqual(state.status, .idle)
        XCTAssertTrue(state.output.isEmpty)
    }

    func testWhitespaceBeginRequestClearsAnArmedTranslation() {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let oldGeneration = state.generation

        arm(state, text: "   \n", runToken: 2)

        XCTAssertNil(state.configuration)
        XCTAssertNil(state.currentRequest)
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.apply(.success("x"), generation: oldGeneration), .ignored)
    }

    func testCompletionMappingUsesOfficialCancelAndUserCancelled() {
        XCTAssertEqual(
            AppleTranslationRequestState.completion(for: .success("ok")),
            .success("ok")
        )
        XCTAssertEqual(
            AppleTranslationRequestState.completion(for: .failure(CancellationError())),
            .cancelled
        )
        XCTAssertEqual(
            AppleTranslationRequestState.completion(for: .failure(CocoaError(.userCancelled))),
            .userCancelled
        )

        let other = NSError(domain: "apple.translation.test", code: 42)
        guard case .failureMessage(let message) =
            AppleTranslationRequestState.completion(for: .failure(other))
        else {
            return XCTFail("expected a generic failure message")
        }
        XCTAssertFalse(message.isEmpty)
    }
}
#endif
