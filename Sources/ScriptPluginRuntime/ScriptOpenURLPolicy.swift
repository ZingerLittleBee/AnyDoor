import Foundation

/// The scheme allowlist for the `openURL` capability (ADR-0009).
///
/// ADR-0009 and spec 018 scope `openURL` to "opening a URL in the default
/// browser", so the runtime confines it to web schemes. Without this guard a
/// plugin declaring only `openURL` could hand a `file://` URL to the default app
/// (opening or revealing a local file) or a custom-scheme URL (launching an
/// arbitrary registered app) — reaching past the declared surface and brushing
/// against ADR-0009's "no filesystem" refusal.
///
/// The same allowlist gates both plugin-supplied URL boundaries: the JS
/// `anydoor.openURL` capability call and a Row Action's `openURL` commit.
/// Scheme comparison is case-insensitive, and a URL with no scheme is rejected.
public enum ScriptOpenURLPolicy {
    /// The only schemes `openURL` may hand to the default browser.
    public static let allowedSchemes: Set<String> = ["http", "https"]

    /// Whether `url` is within the `openURL` capability's declared surface.
    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }
}
