import XCTest
@testable import AnyDoor

final class GoogleFreeManualClock: GoogleFreeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current.addTimeInterval(interval)
    }
}

final class GoogleFreeRateLimitTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        GoogleFreeTranslationHTTPStub.reset()
    }

    override func tearDown() {
        GoogleFreeTranslationHTTPStub.reset()
        super.tearDown()
    }

    // MARK: - Policy

    func testCooldownDurationAbsentHeaderUsesDefault() {
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: nil, now: epoch),
            GoogleFreeRateLimitPolicy.defaultCooldown
        )
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: "  ", now: epoch),
            GoogleFreeRateLimitPolicy.defaultCooldown
        )
    }

    func testCooldownDurationMalformedHeaderUsesDefault() {
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: "soon", now: epoch),
            GoogleFreeRateLimitPolicy.defaultCooldown
        )
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: "30.5", now: epoch),
            GoogleFreeRateLimitPolicy.defaultCooldown
        )
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: "-5", now: epoch),
            GoogleFreeRateLimitPolicy.defaultCooldown
        )
    }

    func testCooldownDurationNumericSecondsHonored() {
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: "10", now: epoch),
            10
        )
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: "  45  ", now: epoch),
            45
        )
    }

    func testCooldownDurationZeroTreatedAsUnusable() {
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: "0", now: epoch),
            GoogleFreeRateLimitPolicy.defaultCooldown
        )
    }

    func testCooldownDurationHugeNumericCappedAtMaximum() {
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: "999999", now: epoch),
            GoogleFreeRateLimitPolicy.maximumCooldown
        )
    }

    func testCooldownDurationHTTPDateHonored() {
        let until = epoch.addingTimeInterval(45)
        let duration = GoogleFreeRateLimitPolicy.cooldownDuration(
            retryAfterHeader: imfDate(until),
            now: epoch
        )
        XCTAssertEqual(duration, 45, accuracy: 0.5)
    }

    func testCooldownDurationPastHTTPDateUsesDefault() {
        let past = epoch.addingTimeInterval(-60)
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: imfDate(past), now: epoch),
            GoogleFreeRateLimitPolicy.defaultCooldown
        )
    }

    func testCooldownDurationFutureHTTPDateCappedAtMaximum() {
        let huge = epoch.addingTimeInterval(60 * 60 * 24)
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: imfDate(huge), now: epoch),
            GoogleFreeRateLimitPolicy.maximumCooldown
        )
    }

    func testRemainingDisplaySecondsClampsToAtLeastOne() {
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.remainingDisplaySeconds(until: epoch, now: epoch),
            1
        )
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.remainingDisplaySeconds(
                until: epoch.addingTimeInterval(-10),
                now: epoch
            ),
            1
        )
        XCTAssertEqual(
            GoogleFreeRateLimitPolicy.remainingDisplaySeconds(
                until: epoch.addingTimeInterval(30),
                now: epoch
            ),
            30
        )
    }

    // MARK: - Limiter

    func testLimiterBlocksUntilExpiryThenAllows() async {
        let clock = GoogleFreeManualClock(epoch)
        let limiter = GoogleFreeRateLimiter(clock: clock)
        guard case .allowed = await limiter.admit() else {
            return XCTFail("expected first admit to be allowed")
        }
        let until = await limiter.noteRateLimited(retryAfterHeader: "30")
        XCTAssertEqual(until.timeIntervalSince(epoch), 30, accuracy: 0.01)

        guard case .throttled(let blocked) = await limiter.admit() else {
            return XCTFail("expected throttle before expiry")
        }
        XCTAssertEqual(blocked, until)

        clock.advance(by: 29)
        guard case .throttled = await limiter.admit() else {
            return XCTFail("expected throttle 1s before expiry")
        }

        clock.advance(by: 1)
        guard case .allowed = await limiter.admit() else {
            return XCTFail("expected admit after expiry")
        }
    }

    func testLimiterOlderSuccessDoesNotClearNewerThrottle() async {
        let clock = GoogleFreeManualClock(epoch)
        let limiter = GoogleFreeRateLimiter(clock: clock)
        guard case .allowed(let older) = await limiter.admit() else {
            return XCTFail("expected older ticket")
        }
        guard case .allowed = await limiter.admit() else {
            return XCTFail("expected newer ticket")
        }
        _ = await limiter.noteRateLimited(retryAfterHeader: "30")
        await limiter.noteSuccess(ticket: older)
        guard case .throttled = await limiter.admit() else {
            return XCTFail("older success must not clear a newer 429")
        }
    }

    // MARK: - Stream

    func testSuccessfulTranslateYieldsDetectedAndFinal() async throws {
        let limiter = GoogleFreeRateLimiter(clock: GoogleFreeManualClock(epoch))
        GoogleFreeTranslationHTTPStub.setHandler { request in
            assertGoogleTranslateURL(request)
            return .ok()
        }
        let chunks = try await collect(provider(limiter).translate(makeRequest()))
        XCTAssertEqual(chunks, [.detected(.english), .final("你好")])
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 1)
    }

    func testStreamHTTP429NumericRetryAfter() async {
        let clock = GoogleFreeManualClock(epoch)
        let limiter = GoogleFreeRateLimiter(clock: clock)
        GoogleFreeTranslationHTTPStub.setHandler { _ in .rateLimited(retryAfter: "10") }
        let error = await translateError(limiter)
        guard case .rateLimited(let until)? = error else {
            return XCTFail("expected rateLimited, got \(String(describing: error))")
        }
        XCTAssertEqual(until.timeIntervalSince(epoch), 10, accuracy: 0.01)
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 1)

        GoogleFreeTranslationHTTPStub.setHandler { _ in .ok() }
        let second = await translateError(limiter)
        guard case .rateLimited? = second else {
            return XCTFail("fresh Enter during cooldown must fail without network")
        }
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 1)
    }

    func testStreamHTTP429HTTPDateRetryAfter() async {
        let clock = GoogleFreeManualClock(epoch)
        let limiter = GoogleFreeRateLimiter(clock: clock)
        let header = imfDate(epoch.addingTimeInterval(45))
        GoogleFreeTranslationHTTPStub.setHandler { _ in .rateLimited(retryAfter: header) }
        let error = await translateError(limiter)
        guard case .rateLimited(let until)? = error else {
            return XCTFail("expected rateLimited, got \(String(describing: error))")
        }
        XCTAssertEqual(until.timeIntervalSince(epoch), 45, accuracy: 0.5)
    }

    func testStreamHTTP429AbsentHeaderUsesDefaultCooldown() async {
        await assertFailFastCooldown(retryAfter: nil, expected: GoogleFreeRateLimitPolicy.defaultCooldown)
    }

    func testStreamHTTP429MalformedHeaderUsesDefaultCooldown() async {
        await assertFailFastCooldown(retryAfter: "not-a-date", expected: GoogleFreeRateLimitPolicy.defaultCooldown)
    }

    func testStreamHTTP429HugeRetryAfterCapped() async {
        let clock = GoogleFreeManualClock(epoch)
        let limiter = GoogleFreeRateLimiter(clock: clock)
        GoogleFreeTranslationHTTPStub.setHandler { _ in .rateLimited(retryAfter: "999999") }
        let error = await translateError(limiter)
        guard case .rateLimited(let until)? = error else {
            return XCTFail("expected rateLimited, got \(String(describing: error))")
        }
        XCTAssertEqual(
            until.timeIntervalSince(epoch),
            GoogleFreeRateLimitPolicy.maximumCooldown,
            accuracy: 0.01
        )

        clock.advance(by: GoogleFreeRateLimitPolicy.defaultCooldown)
        guard case .rateLimited? = await translateError(limiter) else {
            return XCTFail("capped cooldown must still block after the default window")
        }
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 1)

        clock.advance(
            by: GoogleFreeRateLimitPolicy.maximumCooldown - GoogleFreeRateLimitPolicy.defaultCooldown
        )
        GoogleFreeTranslationHTTPStub.setHandler { _ in .ok() }
        let chunks = try? await collect(provider(limiter).translate(makeRequest()))
        XCTAssertEqual(chunks?.last, .final("你好"))
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 2)
    }

    func testStreamHTTP429PastHTTPDateUsesDefaultCooldown() async {
        let past = imfDate(epoch.addingTimeInterval(-120))
        await assertFailFastCooldown(retryAfter: past, expected: GoogleFreeRateLimitPolicy.defaultCooldown)
    }

    func testNewProviderInstancesShareLimiterWithoutNetwork() async {
        let clock = GoogleFreeManualClock(epoch)
        let limiter = GoogleFreeRateLimiter(clock: clock)
        let session = GoogleFreeTranslationHTTPStub.session()
        GoogleFreeTranslationHTTPStub.setHandler { _ in .rateLimited(retryAfter: "30") }

        let first = GoogleFreeTranslationProvider(id: "g1", session: session, limiter: limiter)
        let error = await firstError(first.translate(makeRequest()))
        guard case .rateLimited? = error as? TranslationProviderError else {
            return XCTFail("expected first instance to record 429")
        }
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 1)

        let second = GoogleFreeTranslationProvider(id: "g2", session: session, limiter: limiter)
        let blocked = await firstError(second.translate(makeRequest("other")))
        guard case .rateLimited? = blocked as? TranslationProviderError else {
            return XCTFail("second instance must share cooldown")
        }
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 1)
        let urls = GoogleFreeTranslationHTTPStub.recordedRequests.compactMap(\.url)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.host, "translate.googleapis.com")
        XCTAssertEqual(urls.first?.path, "/translate_a/single")
    }

    func testCooldownExpiryAllowsNetworkAgain() async throws {
        let clock = GoogleFreeManualClock(epoch)
        let limiter = GoogleFreeRateLimiter(clock: clock)
        GoogleFreeTranslationHTTPStub.setHandler { _ in .rateLimited(retryAfter: "30") }
        _ = await translateError(limiter)

        clock.advance(by: 30)
        GoogleFreeTranslationHTTPStub.setHandler { _ in .ok() }
        let chunks = try await collect(provider(limiter).translate(makeRequest()))
        XCTAssertEqual(chunks.last, .final("你好"))
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 2)
    }

    func testCancellationDuringNetworkDoesNotPublishOrThrottle() async throws {
        let clock = GoogleFreeManualClock(epoch)
        let limiter = GoogleFreeRateLimiter(clock: clock)
        GoogleFreeTranslationHTTPStub.setHandler { _ in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return .ok()
        }
        let stream = provider(limiter).translate(makeRequest())
        let task = Task { try await collect(stream) }
        try await waitUntil { GoogleFreeTranslationHTTPStub.requestCount >= 1 }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation to finish the stream without success")
        } catch is CancellationError {
            // Provider maps URLSession cancel onto CancellationError.
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 1)

        GoogleFreeTranslationHTTPStub.setHandler { _ in .ok() }
        let chunks = try await collect(provider(limiter).translate(makeRequest()))
        XCTAssertEqual(chunks.last, .final("你好"))
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 2)
    }

    func testNon429DoesNotStartCooldown() async {
        let clock = GoogleFreeManualClock(epoch)
        let limiter = GoogleFreeRateLimiter(clock: clock)
        GoogleFreeTranslationHTTPStub.setHandler { _ in .status(500) }
        let error = await translateError(limiter)
        XCTAssertEqual(error, .badResponse(500))
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 1)

        GoogleFreeTranslationHTTPStub.setHandler { _ in .ok() }
        let chunks = try? await collect(provider(limiter).translate(makeRequest()))
        XCTAssertEqual(chunks?.last, .final("你好"))
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 2)
    }

    func testSuccessDoesNotEraseNewerThrottleState() async throws {
        let clock = GoogleFreeManualClock(epoch)
        let limiter = GoogleFreeRateLimiter(clock: clock)
        let session = GoogleFreeTranslationHTTPStub.session()
        let firstGate = ReleaseGate()
        defer { firstGate.release() }
        let indexLock = NSLock()
        var index = 0
        GoogleFreeTranslationHTTPStub.setHandler { _ in
            let n: Int = {
                indexLock.lock()
                defer { indexLock.unlock() }
                index += 1
                return index
            }()
            if n == 1 {
                await firstGate.wait()
                return .ok()
            }
            return .rateLimited(retryAfter: "30")
        }

        let older = GoogleFreeTranslationProvider(id: "older", session: session, limiter: limiter)
        let newer = GoogleFreeTranslationProvider(id: "newer", session: session, limiter: limiter)
        let olderTask = Task { try await collect(older.translate(makeRequest("one"))) }
        try await waitUntil { GoogleFreeTranslationHTTPStub.requestCount >= 1 }

        let newerError = await firstError(newer.translate(makeRequest("two")))
        guard case .rateLimited? = newerError as? TranslationProviderError else {
            return XCTFail("expected newer 429, got \(String(describing: newerError))")
        }

        firstGate.release()
        let olderChunks = try await olderTask.value
        XCTAssertEqual(olderChunks.last, .final("你好"))
        let countAfterConcurrent = GoogleFreeTranslationHTTPStub.requestCount

        let third = GoogleFreeTranslationProvider(id: "third", session: session, limiter: limiter)
        let thirdError = await firstError(third.translate(makeRequest("three")))
        guard case .rateLimited? = thirdError as? TranslationProviderError else {
            return XCTFail("older success must not clear the newer cooldown")
        }
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, countAfterConcurrent)
    }

    func testEmptyInputDoesNotContactNetwork() async {
        let limiter = GoogleFreeRateLimiter(clock: GoogleFreeManualClock(epoch))
        GoogleFreeTranslationHTTPStub.setHandler { _ in .ok() }
        let error = await firstError(
            provider(limiter).translate(TranslationRequest(text: "  ", source: nil, target: .english))
        )
        XCTAssertEqual(error as? TranslationProviderError, .emptyInput)
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 0)
    }

    @MainActor
    func testRateLimitedErrorTextIsLocalizedNotGenericHTTP() {
        let until = Date().addingTimeInterval(120)
        let seconds = GoogleFreeRateLimitPolicy.remainingDisplaySeconds(until: until)
        let message = translationErrorMessage(
            TranslationProviderError.rateLimited(retryAfter: until)
        )
        XCTAssertEqual(message, L(.translationErrorRateLimited, seconds))
        XCTAssertNotEqual(message, L(.translationErrorHTTP, 429))
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - Helpers

    private func makeRequest(_ text: String = "hello") -> TranslationRequest {
        TranslationRequest(text: text, source: nil, target: .simplifiedChinese)
    }

    private func provider(_ limiter: GoogleFreeRateLimiter) -> GoogleFreeTranslationProvider {
        GoogleFreeTranslationProvider(
            id: "google",
            session: GoogleFreeTranslationHTTPStub.session(),
            limiter: limiter
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<TranslationChunk, Error>
    ) async throws -> [TranslationChunk] {
        var chunks: [TranslationChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    private func firstError(_ stream: AsyncThrowingStream<TranslationChunk, Error>) async -> Error? {
        do {
            for try await _ in stream {}
            return nil
        } catch {
            return error
        }
    }

    private func translateError(_ limiter: GoogleFreeRateLimiter) async -> TranslationProviderError? {
        await firstError(provider(limiter).translate(makeRequest())) as? TranslationProviderError
    }

    private func assertFailFastCooldown(retryAfter: String?, expected: TimeInterval) async {
        let clock = GoogleFreeManualClock(epoch)
        let limiter = GoogleFreeRateLimiter(clock: clock)
        GoogleFreeTranslationHTTPStub.setHandler { _ in .rateLimited(retryAfter: retryAfter) }
        let error = await translateError(limiter)
        guard case .rateLimited(let until)? = error else {
            return XCTFail("expected rateLimited, got \(String(describing: error))")
        }
        XCTAssertEqual(until.timeIntervalSince(epoch), expected, accuracy: 0.5)
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 1)

        GoogleFreeTranslationHTTPStub.setHandler { _ in .ok() }
        guard case .rateLimited? = await translateError(limiter) else {
            return XCTFail("fresh Enter during cooldown must fail without network")
        }
        XCTAssertEqual(GoogleFreeTranslationHTTPStub.requestCount, 1)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ predicate: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() > deadline {
                XCTFail("timed out waiting for HTTP stub")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func imfDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

}

private func assertGoogleTranslateURL(_ request: URLRequest) {
    let url = request.url
    XCTAssertEqual(url?.host, "translate.googleapis.com")
    XCTAssertEqual(url?.path, "/translate_a/single")
    XCTAssertEqual(request.httpMethod, "GET")
    guard let url else { return }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    XCTAssertEqual(value("client"), "gtx")
    XCTAssertEqual(value("dt"), "t")
    XCTAssertEqual(value("q"), "hello")
}

/// Holds the first in-flight stub response until the test releases it.
private final class ReleaseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        isOpen = true
        let waiters = waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
