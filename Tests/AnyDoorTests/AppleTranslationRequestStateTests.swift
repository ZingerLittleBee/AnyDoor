import XCTest
@testable import AnyDoor
#if canImport(Translation)
import Translation
#endif

#if canImport(Translation)
/// Production-seam tests for Apple translate request ownership and
/// `TranslationSession.Configuration` scheduling. Assertions use the SDK type's
/// own `==` and `version` — not a copied mock — so same-pair `invalidate()` is
/// distinguished from a no-op reassignment of an equal pair. Publication also
/// requires the scheduled `Request` and the live coordinator `runToken`.
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

    @discardableResult
    private func apply(_ completion: AppleTranslationRequestState.Completion,
                       on state: AppleTranslationRequestState,
                       request: AppleTranslationRequestState.Request? = nil,
                       liveRunToken: Int? = nil) throws -> AppleTranslationRequestState.ApplyOutcome {
        let request = try XCTUnwrap(request ?? state.currentRequest)
        return state.apply(completion, request: request, liveRunToken: liveRunToken ?? request.runToken)
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

    func testSupersededSuccessDoesNotPublishOrReplaceNewerLoading() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let old = try XCTUnwrap(state.currentRequest)
        arm(state, text: "cool", runToken: 2)

        XCTAssertEqual(try apply(.success("旧"), on: state, request: old, liveRunToken: 2), .ignored)
        XCTAssertEqual(state.status, .loading)
        XCTAssertTrue(state.output.isEmpty)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.currentRequest?.runToken, 2)

        XCTAssertEqual(try apply(.success("新"), on: state, liveRunToken: 2), .publishedSuccess)
        XCTAssertEqual(state.status, .success)
        XCTAssertEqual(state.output, "新")
    }

    func testSupersededFailureDoesNotPublishIntoNewerRequest() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let old = try XCTUnwrap(state.currentRequest)
        arm(state, text: "cool", runToken: 2)

        XCTAssertEqual(try apply(.failureMessage("stale"), on: state, request: old, liveRunToken: 2), .ignored)
        XCTAssertEqual(state.status, .loading)
        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.output.isEmpty)

        XCTAssertEqual(try apply(.failureMessage("fresh"), on: state, liveRunToken: 2), .publishedFailure)
        XCTAssertEqual(state.status, .failure)
        XCTAssertEqual(state.errorMessage, "fresh")
    }

    func testCancellationNeverSettlesEvenForOwningGeneration() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let old = try XCTUnwrap(state.currentRequest)
        arm(state, text: "cool", runToken: 2)

        XCTAssertEqual(try apply(.cancelled, on: state, request: old, liveRunToken: 2), .ignored)
        XCTAssertEqual(state.status, .loading)

        XCTAssertEqual(try apply(.cancelled, on: state, liveRunToken: 2), .ignored)
        XCTAssertEqual(state.status, .loading)
        XCTAssertTrue(state.output.isEmpty)
        XCTAssertNil(state.errorMessage)
    }

    func testOwningUserCancelledResetsOnlyThatGeneration() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let old = try XCTUnwrap(state.currentRequest)
        arm(state, text: "cool", runToken: 2)

        XCTAssertEqual(try apply(.userCancelled, on: state, request: old, liveRunToken: 2), .ignored)
        XCTAssertEqual(state.status, .loading)

        XCTAssertEqual(try apply(.userCancelled, on: state, liveRunToken: 2), .resetToIdle)
        XCTAssertEqual(state.status, .idle)
        XCTAssertTrue(state.output.isEmpty)
    }

    func testEmptyInputClearsConfigurationAndIgnoresStaleSuccess() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let old = try XCTUnwrap(state.currentRequest)
        XCTAssertNotNil(state.configuration)

        state.clearArmedTranslation()

        XCTAssertNil(state.configuration)
        XCTAssertNil(state.currentRequest)
        XCTAssertEqual(state.status, .idle)
        XCTAssertGreaterThan(state.generation, old.generation)
        XCTAssertEqual(try apply(.success("迟到"), on: state, request: old, liveRunToken: old.runToken), .ignored)
        XCTAssertEqual(state.status, .idle)
        XCTAssertTrue(state.output.isEmpty)
    }

    func testWhitespaceBeginRequestClearsAnArmedTranslation() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let old = try XCTUnwrap(state.currentRequest)

        arm(state, text: "   \n", runToken: 2)

        XCTAssertNil(state.configuration)
        XCTAssertNil(state.currentRequest)
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(try apply(.success("x"), on: state, request: old, liveRunToken: old.runToken), .ignored)
    }

    func testAdvancedCoordinatorRunTokenDoesNotPublishUnrearmedGeneration() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", runToken: 1)
        let armed = try XCTUnwrap(state.currentRequest)

        // Coordinator translate() already bumped runToken; Apple onChange has
        // not rearmed. The still-owning generation must not flash a result.
        XCTAssertEqual(try apply(.success("旧"), on: state, request: armed, liveRunToken: 2), .ignored)
        XCTAssertEqual(state.status, .loading)
        XCTAssertTrue(state.output.isEmpty)
        XCTAssertEqual(state.generation, armed.generation)
        XCTAssertEqual(state.currentRequest, armed)

        XCTAssertEqual(try apply(.success("ok"), on: state, request: armed, liveRunToken: 1), .publishedSuccess)
        XCTAssertEqual(state.output, "ok")
    }

    func testScheduledRequestCaptureCannotImpersonateNewerRequest() throws {
        let state = AppleTranslationRequestState()
        arm(state, text: "cool", source: nil, target: .english, runID: "old", runToken: 1)
        let scheduled = try XCTUnwrap(state.currentRequest)

        arm(state, text: "hello", source: .english, target: .simplifiedChinese, runID: "new", runToken: 2)

        XCTAssertEqual(scheduled.text, "cool")
        XCTAssertNil(scheduled.source)
        XCTAssertEqual(scheduled.target, .english)
        XCTAssertEqual(scheduled.generation, 1)
        XCTAssertNotEqual(scheduled, state.currentRequest)
        XCTAssertEqual(state.currentRequest?.text, "hello")

        XCTAssertEqual(try apply(.success("来自旧会话"), on: state, request: scheduled, liveRunToken: 2), .ignored)
        XCTAssertEqual(state.status, .loading)
        XCTAssertTrue(state.output.isEmpty)

        XCTAssertEqual(try apply(.success("新"), on: state, liveRunToken: 2), .publishedSuccess)
        XCTAssertEqual(state.output, "新")
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
