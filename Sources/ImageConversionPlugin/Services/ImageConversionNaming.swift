import PluginInterface
import PluginSupport
import Foundation

enum ImageConversionNaming {
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
