import Foundation

/// One converted result surfaced inline by the command palette's developer
/// tools. Pure data — `output` is both the row title and the clipboard text.
struct DevToolResult: Hashable, Sendable {
    /// Stable, fine-grained identifier (e.g. `"base64.encode"`, `"hash.sha256"`,
    /// `"ts.utc"`). Drives the row id and the view's localized tool label.
    let toolID: String
    /// The conversion result — shown as the row title and copied on Return.
    let output: String
}
