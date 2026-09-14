import Foundation

/// Instant source for Google's fail-fast cooldown. Production uses the wall
/// clock; tests inject a controllable clock so expiry is deterministic.
protocol GoogleFreeClock: Sendable {
    var now: Date { get }
}

struct GoogleFreeSystemClock: GoogleFreeClock {
    var now: Date { Date() }
}

/// Cooldown numbers and `Retry-After` parsing for the key-free Google endpoint.
///
/// Fail-fast policy (no automatic retries and no sleeping in the provider):
/// - Default cooldown is 30 seconds when `Retry-After` is absent or unusable
///   (malformed, non-positive delay-seconds, or an HTTP-date in the past).
/// - Honored delay-seconds and future HTTP-dates are capped at 5 minutes.
/// - A fresh Enter during an active cooldown fails immediately without network.
enum GoogleFreeRateLimitPolicy {
    static let defaultCooldown: TimeInterval = 30
    static let maximumCooldown: TimeInterval = 5 * 60

    /// Duration to block new Google network calls after an HTTP 429.
    static func cooldownDuration(retryAfterHeader: String?, now: Date) -> TimeInterval {
        guard let raw = retryAfterHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return defaultCooldown
        }
        if let seconds = parseDelaySeconds(raw) {
            guard seconds > 0 else { return defaultCooldown }
            return min(TimeInterval(seconds), maximumCooldown)
        }
        if let date = parseHTTPDate(raw) {
            let delta = date.timeIntervalSince(now)
            guard delta > 0 else { return defaultCooldown }
            return min(delta, maximumCooldown)
        }
        return defaultCooldown
    }

    /// Whole seconds remaining for the localized 429 message, always at least 1.
    static func remainingDisplaySeconds(until: Date, now: Date = Date()) -> Int {
        max(1, Int(until.timeIntervalSince(now).rounded(.up)))
    }

    /// RFC 9110 `delay-seconds` = 1*DIGIT. Values that do not fit in `Int64`
    /// are treated as unusable (caller falls back to the default cooldown).
    private static func parseDelaySeconds(_ raw: String) -> Int64? {
        guard !raw.isEmpty, raw.unicodeScalars.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        return Int64(raw)
    }

    /// RFC 9110 HTTP-date: IMF-fixdate, obsolete RFC 850, and asctime.
    private static func parseHTTPDate(_ raw: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss 'GMT'",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM dd HH:mm:ss yyyy",
            "EEE MMM  d HH:mm:ss yyyy",
        ]
        let locale = Locale(identifier: "en_US_POSIX")
        let gmt = TimeZone(secondsFromGMT: 0)
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = gmt
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
    }
}

/// Generation captured at admit-time so a stale in-flight success cannot clear
/// a 429 that landed later.
struct GoogleFreeRateLimitTicket: Sendable, Equatable {
    let generation: UInt64
}

enum GoogleFreeAdmission: Sendable, Equatable {
    case allowed(GoogleFreeRateLimitTicket)
    case throttled(until: Date)
}

/// Cross-Enter cooldown for the key-free Google provider. The factory rebuilds
/// a provider on every translate, so production uses ``shared``; tests inject
/// an isolated instance and clock.
actor GoogleFreeRateLimiter {
    static let shared = GoogleFreeRateLimiter()

    private let clock: any GoogleFreeClock
    private var blockedUntil: Date?
    private var generation: UInt64 = 0

    init(clock: any GoogleFreeClock = GoogleFreeSystemClock()) {
        self.clock = clock
    }

    func admit() -> GoogleFreeAdmission {
        let now = clock.now
        if let blockedUntil, now < blockedUntil {
            return .throttled(until: blockedUntil)
        }
        return .allowed(GoogleFreeRateLimitTicket(generation: generation))
    }

    /// Records a 429. Returns the instant after which a new Enter may network.
    /// A longer still-active cooldown is kept; generation always advances so an
    /// older in-flight success cannot erase this throttle.
    @discardableResult
    func noteRateLimited(retryAfterHeader: String?) -> Date {
        let now = clock.now
        let proposed = now.addingTimeInterval(
            GoogleFreeRateLimitPolicy.cooldownDuration(retryAfterHeader: retryAfterHeader, now: now)
        )
        generation &+= 1
        let until: Date
        if let existing = blockedUntil, existing > now, existing > proposed {
            until = existing
        } else {
            until = proposed
        }
        blockedUntil = until
        return until
    }

    func noteSuccess(ticket: GoogleFreeRateLimitTicket) {
        guard ticket.generation == generation else { return }
        blockedUntil = nil
    }
}
