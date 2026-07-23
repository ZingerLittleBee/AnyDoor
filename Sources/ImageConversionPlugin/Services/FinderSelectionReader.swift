import Foundation
import PluginInterface

/// Reads the current Finder selection and echoes its image files into the
/// Conversion Basket. Reading happens only at window-activation time (no live
/// selection tracking). Failure is silent by design: a missing Automation
/// permission, Finder not running, or an empty selection all yield an empty
/// result so the window simply opens with an empty basket.
enum FinderSelectionReader {
    /// File extensions that ImageIO can typically decode. The authoritative
    /// image check happens later against the filesystem (`ImageConverter`), so
    /// this list only needs to be a permissive first pass for the pure parser.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "jfif", "gif", "heic", "heif", "heics",
        "webp", "tiff", "tif", "bmp", "dib", "avif", "avifs", "ico", "icns",
        "jp2", "j2k", "jpf", "jpx", "psd", "tga", "pict", "pct", "exr", "hdr",
        "cr2", "cr3", "nef", "arw", "dng", "orf", "raf", "rw2", "sr2", "srf",
        "pef", "x3f", "erf",
    ]

    /// Best-effort read of the current Finder selection as image-file URLs.
    /// Returns an empty array on any AppleScript failure or empty selection.
    @MainActor
    static func read(host: PluginHostContext) async -> [URL] {
        do {
            let output = try await host.runAppleScript(selectionScript)
            return parse(output)
        } catch {
            // Silent by design: an unavailable Automation permission or a
            // Finder error must not surface an error to the user.
            return []
        }
    }

    /// Pure parser: newline-joined POSIX paths in, image-file URLs out.
    /// Blank lines are skipped, entries are trimmed, and only paths whose
    /// extension is a known image type are kept.
    static func parse(_ output: String) -> [URL] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// AppleScript returning the Finder selection as newline-joined POSIX paths.
    private static let selectionScript = """
    tell application "Finder"
        set theSelection to selection
        set posixPaths to {}
        repeat with anItem in theSelection
            set end of posixPaths to POSIX path of (anItem as alias)
        end repeat
        set AppleScript's text item delimiters to linefeed
        set outputText to posixPaths as text
        set AppleScript's text item delimiters to ""
        return outputText
    end tell
    """
}
