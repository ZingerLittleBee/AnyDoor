import CryptoKit
import Foundation

/// Pure, total facade for the command palette's inline developer tools:
/// detection + conversion + formatting, mirroring `Calculator`. Never throws,
/// never crashes; returns an empty array when nothing applies.
///
/// `now` / `timeZone` are injected so timestamp rendering is deterministic in
/// tests (default `.current` in production). `now` is reserved for a future
/// `now`-keyword row and is currently unused.
enum DevTools {
    static func detect(
        query: String,
        now: Date? = nil,
        timeZone: TimeZone = .current
    ) -> [DevToolResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var rows: [DevToolResult] = []
        rows += base64Rows(trimmed)
        rows += urlRows(trimmed)
        rows += jsonRows(trimmed)
        rows += hashRows(trimmed)
        rows += timestampRows(trimmed, timeZone: timeZone)
        return rows
    }

    // MARK: - Base64

    private static func base64Rows(_ s: String) -> [DevToolResult] {
        guard let body = keywordBody(s, keyword: "base64") else { return [] }
        var rows: [DevToolResult] = []
        if let data = body.data(using: .utf8) {
            rows.append(DevToolResult(toolID: "base64.encode", output: data.base64EncodedString()))
        }
        // Decode row only when the body is itself valid base64 of printable UTF-8.
        if let decoded = Data(base64Encoded: body),
           let text = String(data: decoded, encoding: .utf8), !text.isEmpty {
            rows.append(DevToolResult(toolID: "base64.decode", output: text))
        }
        return rows
    }

    // MARK: - URL percent-encoding

    /// RFC 3986 unreserved set — everything else is percent-escaped.
    private static let urlUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func urlRows(_ s: String) -> [DevToolResult] {
        guard let body = keywordBody(s, keyword: "url") else { return [] }
        var rows: [DevToolResult] = []
        if let encoded = body.addingPercentEncoding(withAllowedCharacters: urlUnreserved) {
            rows.append(DevToolResult(toolID: "url.encode", output: encoded))
        }
        // Decode row only when the body actually contains percent escapes.
        if let decoded = body.removingPercentEncoding, decoded != body {
            rows.append(DevToolResult(toolID: "url.decode", output: decoded))
        }
        return rows
    }

    // MARK: - JSON (auto-detected)

    private static func jsonRows(_ s: String) -> [DevToolResult] {
        guard let first = s.first, first == "{" || first == "[" else { return [] }
        guard let data = s.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var rows: [DevToolResult] = []
        if let pretty = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: pretty, encoding: .utf8) {
            rows.append(DevToolResult(toolID: "json.pretty", output: text))
        }
        if let mini = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        ), let text = String(data: mini, encoding: .utf8) {
            rows.append(DevToolResult(toolID: "json.minify", output: text))
        }
        return rows
    }

    // MARK: - Hash

    private static func hashRows(_ s: String) -> [DevToolResult] {
        var rows: [DevToolResult] = []
        if let body = keywordBody(s, keyword: "md5"), let data = body.data(using: .utf8) {
            rows.append(DevToolResult(toolID: "hash.md5", output: hex(Insecure.MD5.hash(data: data))))
        }
        if let body = keywordBody(s, keyword: "sha1"), let data = body.data(using: .utf8) {
            rows.append(DevToolResult(toolID: "hash.sha1", output: hex(Insecure.SHA1.hash(data: data))))
        }
        if let body = keywordBody(s, keyword: "sha256"), let data = body.data(using: .utf8) {
            rows.append(DevToolResult(toolID: "hash.sha256", output: hex(SHA256.hash(data: data))))
        }
        return rows
    }

    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Unix timestamp -> date (auto-detected)

    private static let utcZone = TimeZone(identifier: "UTC")!

    private static func timestampRows(_ s: String, timeZone: TimeZone) -> [DevToolResult] {
        // Strong signal: exactly 10 (seconds) or 13 (milliseconds) ASCII digits.
        guard s.allSatisfy({ $0.isASCII && $0.isNumber }), let raw = Double(s) else { return [] }
        let seconds: Double
        switch s.count {
        case 10: seconds = raw
        case 13: seconds = raw / 1000
        default: return []
        }
        let date = Date(timeIntervalSince1970: seconds)
        return [
            DevToolResult(toolID: "ts.local", output: dateString(date, timeZone: timeZone)),
            DevToolResult(toolID: "ts.utc", output: dateString(date, timeZone: utcZone)),
            DevToolResult(toolID: "ts.iso", output: isoString(date)),
        ]
    }

    private static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = utcZone
        return formatter.string(from: date)
    }

    // MARK: - Helpers

    /// Returns the trimmed body of a `"<keyword> <body>"` query (case-insensitive
    /// keyword), or nil when the keyword prefix is absent or the body is empty.
    private static func keywordBody(_ s: String, keyword: String) -> String? {
        let prefix = keyword + " "
        guard s.lowercased().hasPrefix(prefix) else { return nil }
        let body = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }
}
