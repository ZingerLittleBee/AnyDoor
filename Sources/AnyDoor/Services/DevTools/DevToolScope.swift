import Foundation

/// A dev-tool keyword promoted to a search-bar scope badge (Raycast-style).
/// Only the explicit-keyword tools have a scope; JSON / timestamp are
/// auto-detected from content and have none.
enum DevToolScope: String, CaseIterable, Sendable {
    case base64
    case url
    case md5
    case sha1
    case sha256

    /// The keyword the user types to enter this scope.
    var keyword: String { rawValue }

    /// The label shown on the search-bar badge (canonical casing).
    var badgeLabel: String {
        switch self {
        case .base64: return "Base64"
        case .url: return "URL"
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        }
    }

    /// Parse a keyword (case-insensitive) into a scope, or nil when it is not a
    /// scoped dev-tool keyword.
    init?(keyword: String) {
        self.init(rawValue: keyword.lowercased())
    }
}
