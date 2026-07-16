import PluginInterface
import Foundation

enum ImageConversionNaming {
    static func outputURL(
        forFileSource sourceURL: URL,
        target: ImageConversionFormat,
        exists: (URL) -> Bool
    ) -> URL {
        let directory = sourceURL.deletingLastPathComponent()
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let ext = target.fileExtension
        let first = directory.appendingPathComponent("\(base).\(ext)")
        if !exists(first) { return first }

        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent("\(base) \(counter).\(ext)")
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }

    static func outputURL(forFileSource sourceURL: URL, target: ImageConversionFormat) -> URL {
        outputURL(forFileSource: sourceURL, target: target) { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Output URL for a bitmap source, placed in the Downloads directory with a
    /// "Clipboard <timestamp>" base name plus the same " 2"/" 3" collision rule.
    static func outputURL(
        forBitmapInDownloads directory: URL,
        baseName: String,
        target: ImageConversionFormat,
        exists: (URL) -> Bool
    ) -> URL {
        let ext = target.fileExtension
        let first = directory.appendingPathComponent("\(baseName).\(ext)")
        if !exists(first) { return first }

        var counter = 2
        while true {
            let candidate = directory.appendingPathComponent("\(baseName) \(counter).\(ext)")
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }

    static func outputURL(
        forBitmapInDownloads directory: URL,
        baseName: String,
        target: ImageConversionFormat
    ) -> URL {
        outputURL(forBitmapInDownloads: directory, baseName: baseName, target: target) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// "Clipboard <timestamp>" base name for bitmap outputs. Time separators use
    /// "." (":" is illegal in file names).
    static func bitmapBaseName(timestamp: Date, calendar: Calendar = .current) -> String {
        let stamp = CaptureFilename.make(
            template: "YYYY-MM-DD HH.mm.ss",
            date: timestamp,
            calendar: calendar
        )
        return "Clipboard \(stamp)"
    }
}
