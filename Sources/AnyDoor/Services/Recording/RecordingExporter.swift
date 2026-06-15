import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Turns a captured `.mov` into the requested output format. `.mov` is returned
/// as-is; `.mp4` is transcoded via `AVAssetExportSession`; `.gif` is sampled into
/// an animated GIF via `AVAssetImageGenerator` + ImageIO. Completion is always on
/// the main actor.
enum RecordingExporter {
    @MainActor
    static func finalize(mov: URL, to format: RecordingFormat, completion: @escaping @MainActor (URL?) -> Void) {
        switch format {
        case .mov:
            completion(mov)
        case .mp4:
            transcodeToMP4(mov, completion: completion)
        case .gif:
            exportGIF(mov, completion: completion)
        }
    }

    private static func transcodeToMP4(_ mov: URL, completion: @escaping @MainActor (URL?) -> Void) {
        let asset = AVURLAsset(url: mov)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            Task { @MainActor in completion(nil) }
            return
        }
        let out = mov.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out
        export.outputFileType = .mp4
        // `AVAssetExportSession` is non-Sendable, but the completion handler runs
        // once after the export finishes and only reads `status`; mark the capture
        // unsafe to satisfy strict concurrency without a behavior change.
        nonisolated(unsafe) let session = export
        session.exportAsynchronously {
            let ok = session.status == .completed
            Task { @MainActor in
                if ok { try? FileManager.default.removeItem(at: mov) }
                completion(ok ? out : nil)
            }
        }
    }

    private static func exportGIF(_ mov: URL, fps: Double = 12, completion: @escaping @MainActor (URL?) -> Void) {
        Task.detached {
            let asset = AVURLAsset(url: mov)
            guard let duration = try? await asset.load(.duration) else {
                await MainActor.run { completion(nil) }
                return
            }
            let seconds = CMTimeGetSeconds(duration)
            guard seconds > 0 else { await MainActor.run { completion(nil) }; return }
            let frameCount = max(1, min(Int(seconds * fps), 400)) // cap frames so GIFs stay sane

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

            let out = mov.deletingPathExtension().appendingPathExtension("gif")
            try? FileManager.default.removeItem(at: out)
            guard let dest = CGImageDestinationCreateWithURL(
                out as CFURL, UTType.gif.identifier as CFString, frameCount, nil
            ) else {
                await MainActor.run { completion(nil) }
                return
            }
            CGImageDestinationSetProperties(dest, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
            let frameProps = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]
            ] as CFDictionary

            var added = 0
            for i in 0..<frameCount {
                let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
                if let result = try? await generator.image(at: time) {
                    CGImageDestinationAddImage(dest, result.image, frameProps)
                    added += 1
                }
            }
            let ok = added > 0 && CGImageDestinationFinalize(dest)
            await MainActor.run {
                if ok { try? FileManager.default.removeItem(at: mov) }
                completion(ok ? out : nil)
            }
        }
    }
}
