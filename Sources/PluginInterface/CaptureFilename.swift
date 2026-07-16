import Foundation

/// Pure helpers for turning a naming template + date into a filesystem-safe file
/// name, and for de-duplicating against existing files. No I/O — callers inject
/// the existence check so this stays unit-testable.
public enum CaptureFilename {
    /// Expands `YYYY MM DD HH mm ss` tokens (longest-first so `MM`/`mm` are
    /// unambiguous), then strips characters illegal in a file name.
    public static func make(template: String, date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?, _ width: Int) -> String {
            String(format: "%0\(width)d", v ?? 0)
        }
        var out = template
        out = out.replacingOccurrences(of: "YYYY", with: pad(c.year, 4))
        out = out.replacingOccurrences(of: "MM", with: pad(c.month, 2))
        out = out.replacingOccurrences(of: "DD", with: pad(c.day, 2))
        out = out.replacingOccurrences(of: "HH", with: pad(c.hour, 2))
        out = out.replacingOccurrences(of: "mm", with: pad(c.minute, 2))
        out = out.replacingOccurrences(of: "ss", with: pad(c.second, 2))
        // Strip path separators and other illegal filename characters.
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return out.components(separatedBy: illegal).joined()
    }

    /// Returns `"<base>.<ext>"`, or `"<base> N.<ext>"` with the smallest N >= 2
    /// that is free per `exists`.
    public static func resolve(base: String, ext: String, exists: (String) -> Bool) -> String {
        let first = "\(base).\(ext)"
        if !exists(first) { return first }
        var n = 2
        while exists("\(base) \(n).\(ext)") { n += 1 }
        return "\(base) \(n).\(ext)"
    }
}
