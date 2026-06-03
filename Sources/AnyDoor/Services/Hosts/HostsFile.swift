import Foundation

/// Pure, side-effect-free parsing and composition of `/etc/hosts`.
///
/// `/etc/hosts` is treated as: prefix (system content) + an optional AnyDoor
/// managed block + suffix (also system content). AnyDoor only ever rewrites
/// the managed block; prefix and suffix are preserved verbatim.
enum HostsFile {
    static let beginMarker = "# >>> AnyDoor managed block - do not edit below this line >>>"
    static let endMarker = "# <<< AnyDoor managed block end <<<"

    struct Parsed: Equatable {
        var prefix: String
        var managed: String?
        var suffix: String
    }

    /// Split raw hosts text. When the markers are absent or malformed (begin
    /// without a following end), the whole file is treated as system prefix.
    static func parse(_ raw: String) -> Parsed {
        let lines = raw.components(separatedBy: "\n")
        guard let beginIdx = lines.firstIndex(of: beginMarker) else {
            return Parsed(prefix: raw, managed: nil, suffix: "")
        }
        let afterBegin = lines[(beginIdx + 1)...]
        guard let endOffset = afterBegin.firstIndex(of: endMarker) else {
            return Parsed(prefix: raw, managed: nil, suffix: "")
        }
        let prefix = lines[..<beginIdx].joined(separator: "\n")
        let managed = lines[(beginIdx + 1)..<endOffset].joined(separator: "\n")
        // Strip any leading blank lines that were the separator between the
        // managed block and the following system content; this keeps round-trips
        // stable when compose writes a "\n\n" join between sections.
        let rawSuffix = lines[(endOffset + 1)...].joined(separator: "\n")
        let suffix = trimLeadingNewlines(rawSuffix)
        return Parsed(prefix: prefix, managed: managed, suffix: suffix)
    }

    /// Recompose hosts text: preserved prefix, a freshly built managed block
    /// for the active profiles (omitted entirely when none), then preserved
    /// suffix. Output always ends with a single trailing newline.
    static func compose(parsed: Parsed, activeProfiles: [(name: String, content: String)]) -> String {
        var sections: [String] = []

        let prefix = trimTrailingNewlines(parsed.prefix)
        if !prefix.isEmpty { sections.append(prefix) }

        if !activeProfiles.isEmpty {
            var blockLines: [String] = [beginMarker]
            for profile in activeProfiles {
                blockLines.append("# --- \(sanitizeName(profile.name)) ---")
                let body = trimTrailingNewlines(sanitizeContent(profile.content))
                if !body.isEmpty { blockLines.append(body) }
            }
            blockLines.append(endMarker)
            sections.append(blockLines.joined(separator: "\n"))
        }

        let suffix = trimTrailingNewlines(parsed.suffix)
        if !suffix.isEmpty { sections.append(suffix) }

        return sections.joined(separator: "\n\n") + "\n"
    }

    /// Remove any lines from profile content that would forge our markers.
    private static func sanitizeContent(_ content: String) -> String {
        content
            .components(separatedBy: "\n")
            .filter { $0 != beginMarker && $0 != endMarker }
            .joined(separator: "\n")
    }

    /// Keep profile names single-line so they cannot break the comment header.
    private static func sanitizeName(_ name: String) -> String {
        name.replacingOccurrences(of: "\n", with: " ")
    }

    private static func trimTrailingNewlines(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    private static func trimLeadingNewlines(_ s: String) -> String {
        var out = s
        while out.hasPrefix("\n") { out.removeFirst() }
        return out
    }
}
