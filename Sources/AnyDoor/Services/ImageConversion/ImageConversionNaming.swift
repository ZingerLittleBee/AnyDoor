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
}
