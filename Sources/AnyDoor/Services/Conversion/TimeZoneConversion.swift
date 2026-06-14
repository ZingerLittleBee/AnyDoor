import Foundation

/// Pure, total time-zone converter for the command palette. Pure given an
/// injected `now` and `localZone`. Returns an empty array on any non-match.
///
/// Two forms (presence of `to` selects the second):
/// - `<time?> <place>` — `<time>` (optional, defaults to `now`) is in the local
///   zone; the row shows that instant's wall-clock in `<place>`. The single-place
///   form requires an explicit time token or a trailing `time` keyword so bare
///   city names don't pollute command/app search.
/// - `<time> <a> to <b>` — `<time>` (required here) is in `<a>`'s zone, shown in
///   `<b>`. The time is mandatory so a bare `<place> to <place>` doesn't pollute search.
enum TimeZoneConversion {
    static func detect(_ query: String, now: Date, localZone: TimeZone) -> [ConversionResult] {
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return [] }

        // Parse an optional leading time token.
        let (time, afterTime) = parseLeadingTime(lowered)
        let rest = afterTime.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return [] }

        // Two-place form when a " to " or "=" connector is present. Requires an
        // explicit time: without one the source zone is meaningless, and gating it
        // stops "la to ny" / "london to tokyo" from polluting command/app search
        // (the same anti-pollution rule the single-place form applies below).
        if let range = rest.range(of: " to ") ?? rest.range(of: "=") {
            guard time != nil else { return [] }
            let sourcePhrase = String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let targetPhrase = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let source = resolve(sourcePhrase), let target = resolve(targetPhrase) else { return [] }
            return [row(time: time, now: now, sourceZone: source.zone, sourceLabel: source.name,
                        target: target)]
        }

        // Single-place form: needs a time token, or a trailing `time` keyword.
        var placePhrase = rest
        var hasTimeKeyword = false
        if placePhrase == "time" { return [] }
        if placePhrase.hasSuffix(" time") {
            placePhrase = String(placePhrase.dropLast(5)).trimmingCharacters(in: .whitespaces)
            hasTimeKeyword = true
        }
        guard time != nil || hasTimeKeyword else { return [] }
        guard let target = resolve(placePhrase) else { return [] }
        return [row(time: time, now: now, sourceZone: localZone, sourceLabel: localSourceLabel,
                    target: target)]
    }

    // MARK: - Row construction

    private static let localSourceLabel = "Local"

    private static func row(time: (hour: Int, minute: Int)?, now: Date,
                            sourceZone: TimeZone, sourceLabel: String, target: Place) -> ConversionResult {
        let instant = resolveInstant(time: time, now: now, sourceZone: sourceZone)
        let timeString = format(instant, in: target.zone)
        let abbr = gmtAbbreviation(target.zone, at: instant)
        let dayMarker = dayOffsetMarker(instant, sourceZone: sourceZone, targetZone: target.zone)
        let display = "\(timeString) \(abbr)\(dayMarker)"
        return ConversionResult(
            kind: .timeZone,
            value: 0,
            display: display,
            copyText: timeString,
            detail: "\(sourceLabel) → \(target.name)",
            symbol: "clock"
        )
    }

    /// The absolute instant for an explicit wall time in `sourceZone` on the
    /// source-zone date of `now`; or just `now` when no time was given.
    private static func resolveInstant(time: (hour: Int, minute: Int)?, now: Date, sourceZone: TimeZone) -> Date {
        guard let time else { return now }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = sourceZone
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = time.hour
        comps.minute = time.minute
        comps.second = 0
        return cal.date(from: comps) ?? now
    }

    private static func format(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// A stable `GMT±H[:MM]` abbreviation (avoids "JST" vs "GMT+9" ambiguity).
    private static func gmtAbbreviation(_ zone: TimeZone, at date: Date) -> String {
        let secs = zone.secondsFromGMT(for: date)
        if secs == 0 { return "GMT" }
        let sign = secs > 0 ? "+" : "-"
        let hours = abs(secs) / 3600
        let minutes = (abs(secs) % 3600) / 60
        return minutes == 0 ? "GMT\(sign)\(hours)" : "GMT\(sign)\(hours):\(String(format: "%02d", minutes))"
    }

    /// `" (+1d)"` / `" (-1d)"` when the target wall date differs from the source.
    /// Compares the wall-clock calendar dates (not absolute instants): each zone's
    /// Y/M/D is rebuilt as a UTC-midnight date so the day diff ignores zone offset.
    private static func dayOffsetMarker(_ instant: Date, sourceZone: TimeZone, targetZone: TimeZone) -> String {
        let utc = TimeZone(identifier: "UTC")!
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = utc

        func wallDate(_ zone: TimeZone) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let c = cal.dateComponents([.year, .month, .day], from: instant)
            return utcCal.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) ?? instant
        }

        let diff = utcCal.dateComponents([.day], from: wallDate(sourceZone), to: wallDate(targetZone)).day ?? 0
        if diff == 0 { return "" }
        return diff > 0 ? " (+\(diff)d)" : " (\(diff)d)"
    }

    // MARK: - Time parsing

    /// Parses a leading time token, returning it (24h) plus the unconsumed remainder.
    private static func parseLeadingTime(_ s: String) -> ((hour: Int, minute: Int)?, String) {
        if let rest = consumeWord("noon", from: s) { return ((12, 0), rest) }
        if let rest = consumeWord("midnight", from: s) { return ((0, 0), rest) }

        // 12-hour with am/pm: "3pm", "3:30pm", "3 pm".
        if let match = matchPrefix(#"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)"#, in: s) {
            let hour12 = Int(match.groups[0]) ?? 0
            let minute = match.groups.count > 1 && !match.groups[1].isEmpty ? (Int(match.groups[1]) ?? 0) : 0
            let isPM = match.groups[2] == "pm"
            var hour = hour12 % 12
            if isPM { hour += 12 }
            guard (0...23).contains(hour), (0...59).contains(minute) else { return (nil, s) }
            return ((hour, minute), String(s[s.index(s.startIndex, offsetBy: match.length)...]))
        }

        // 24-hour with a colon: "15:00", "9:30".
        if let match = matchPrefix(#"^(\d{1,2}):(\d{2})"#, in: s) {
            let hour = Int(match.groups[0]) ?? 0
            let minute = Int(match.groups[1]) ?? 0
            guard (0...23).contains(hour), (0...59).contains(minute) else { return (nil, s) }
            return ((hour, minute), String(s[s.index(s.startIndex, offsetBy: match.length)...]))
        }

        return (nil, s)
    }

    private static func consumeWord(_ word: String, from s: String) -> String? {
        if s == word { return "" }
        if s.hasPrefix(word + " ") { return String(s.dropFirst(word.count + 1)) }
        return nil
    }

    private struct RegexMatch { let length: Int; let groups: [String] }

    private static func matchPrefix(_ pattern: String, in s: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range), m.range.location == 0 else { return nil }
        var groups: [String] = []
        for i in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: s) {
                groups.append(String(s[r]))
            } else {
                groups.append("")
            }
        }
        return RegexMatch(length: m.range.length, groups: groups)
    }

    // MARK: - Place resolution

    private struct Place: Sendable {
        let zone: TimeZone
        let name: String
    }

    private static func resolve(_ phrase: String) -> Place? {
        let key = phrase.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if key == "utc" || key == "gmt" {
            return Place(zone: TimeZone(identifier: "UTC")!, name: "UTC")
        }
        if let entry = cityAliases[key], let zone = TimeZone(identifier: entry.id) {
            return Place(zone: zone, name: entry.name)
        }
        if let id = ianaByLowercase[key], let zone = TimeZone(identifier: id) {
            return Place(zone: zone, name: prettyName(id))
        }
        return nil
    }

    private static func prettyName(_ id: String) -> String {
        let last = id.split(separator: "/").last.map(String.init) ?? id
        return last.replacingOccurrences(of: "_", with: " ")
    }

    private static let ianaByLowercase: [String: String] = {
        Dictionary(TimeZone.knownTimeZoneIdentifiers.map { ($0.lowercased(), $0) },
                   uniquingKeysWith: { first, _ in first })
    }()

    private struct CityEntry: Sendable { let id: String; let name: String }

    /// Curated alias → (IANA id, display name) for the most common cities.
    private static let cityAliases: [String: CityEntry] = {
        var map: [String: CityEntry] = [:]
        func add(_ aliases: [String], _ id: String, _ name: String) {
            for alias in aliases { map[alias] = CityEntry(id: id, name: name) }
        }
        add(["new york", "nyc", "ny"], "America/New_York", "New York")
        add(["los angeles", "la"], "America/Los_Angeles", "Los Angeles")
        add(["san francisco", "sf"], "America/Los_Angeles", "San Francisco")
        add(["chicago"], "America/Chicago", "Chicago")
        add(["denver"], "America/Denver", "Denver")
        add(["toronto"], "America/Toronto", "Toronto")
        add(["vancouver"], "America/Vancouver", "Vancouver")
        add(["mexico city"], "America/Mexico_City", "Mexico City")
        add(["sao paulo", "são paulo"], "America/Sao_Paulo", "São Paulo")
        add(["london"], "Europe/London", "London")
        add(["dublin"], "Europe/Dublin", "Dublin")
        add(["paris"], "Europe/Paris", "Paris")
        add(["berlin"], "Europe/Berlin", "Berlin")
        add(["madrid"], "Europe/Madrid", "Madrid")
        add(["rome"], "Europe/Rome", "Rome")
        add(["amsterdam"], "Europe/Amsterdam", "Amsterdam")
        add(["zurich"], "Europe/Zurich", "Zurich")
        add(["moscow"], "Europe/Moscow", "Moscow")
        add(["istanbul"], "Europe/Istanbul", "Istanbul")
        add(["dubai"], "Asia/Dubai", "Dubai")
        add(["mumbai", "delhi", "new delhi", "bangalore", "kolkata"], "Asia/Kolkata", "India")
        add(["bangkok"], "Asia/Bangkok", "Bangkok")
        add(["singapore"], "Asia/Singapore", "Singapore")
        add(["hong kong", "hk"], "Asia/Hong_Kong", "Hong Kong")
        add(["shanghai", "beijing"], "Asia/Shanghai", "Shanghai")
        add(["taipei"], "Asia/Taipei", "Taipei")
        add(["seoul"], "Asia/Seoul", "Seoul")
        add(["tokyo"], "Asia/Tokyo", "Tokyo")
        add(["osaka"], "Asia/Tokyo", "Osaka")
        add(["sydney"], "Australia/Sydney", "Sydney")
        add(["melbourne"], "Australia/Melbourne", "Melbourne")
        add(["auckland"], "Pacific/Auckland", "Auckland")
        add(["honolulu"], "Pacific/Honolulu", "Honolulu")
        return map
    }()
}
