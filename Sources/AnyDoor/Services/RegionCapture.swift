import CoreGraphics
import Foundation
import ImageIO

/// Errors surfaced by the OCR capture pipeline.
enum OCRError: Error {
    /// screencapture produced a file but it could not be decoded into a CGImage.
    case imageDecodeFailed
}

/// Wraps the native macOS interactive screen-selection tool (`screencapture -i -s`).
/// Owns the temp-file lifecycle.
enum RegionCapture {
    /// Presents the macOS region-selection UI and returns the captured image.
    ///
    /// Returns `nil` when the user cancels — cancellation is detected by the
    /// *absence* of a temp file, because `screencapture`'s cancel exit code is
    /// undocumented and unreliable. Holding Control during selection routes the
    /// capture to the clipboard (native behavior), which also produces no file
    /// and is therefore treated as a cancellation.
    ///
    /// Throws `OCRError.imageDecodeFailed` when a file is produced but cannot be
    /// decoded, and rethrows any process-launch failure.
    static func captureRegion() async throws -> CGImage? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-ocr-\(UUID().uuidString).png")
        let tempPath = tempURL.path
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            // -i: interactive; -s: selection-only (disables spacebar window mode).
            // timeout nil: the user controls how long the selection takes.
            _ = try await ShellRunner.run(
                "/usr/sbin/screencapture",
                args: ["-i", "-s", tempPath],
                timeout: nil
            )
        } catch BuiltinError.shellFailed {
            // Non-zero exit. screencapture's cancel exit code is undocumented,
            // so do not treat this as a failure here — fall through to the
            // file-presence check, which is the reliable signal.
        }
        // A genuine launch failure throws a non-BuiltinError and propagates.

        guard FileManager.default.fileExists(atPath: tempPath) else {
            return nil // user cancelled, or Control-routed the capture to the clipboard
        }
        guard let image = decodeImage(at: tempURL) else {
            throw OCRError.imageDecodeFailed
        }
        return image
    }

    /// Decodes the PNG at `url` into a CGImage. Internal (not private) so the
    /// file-deletion-survival behavior can be unit-tested.
    ///
    /// `kCGImageSourceShouldCacheImmediately` forces a full pixel decode at creation
    /// time, while the file still exists. Without it the returned CGImage decodes
    /// lazily on first pixel access — but the caller deletes the temp file as soon as
    /// `captureRegion()` returns, so a lazy image would read back nothing.
    static func decodeImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }
}
