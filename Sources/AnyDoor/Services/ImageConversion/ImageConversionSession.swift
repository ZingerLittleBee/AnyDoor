import Foundation

/// One conversion source: either an on-disk file (output beside it) or an
/// in-memory bitmap such as a pasted screenshot (output to Downloads).
enum ImageConversionInput: Sendable {
    case file(URL)
    case bitmap(Data)
}

/// Whether a conversion source was an on-disk file or an in-memory bitmap.
/// Stored as a raw string on `ImageConversionRecord`.
enum ImageConversionSourceKind: String, Sendable {
    case file
    case bitmap
}

/// One produced output, carrying the metadata a history record needs.
struct ImageConversionOutput: Equatable, Sendable {
    let inputIndex: Int
    let sourceName: String
    let sourceKind: ImageConversionSourceKind
    let outputURL: URL
}

struct ImageConversionSummary: Equatable, Sendable {
    let converted: Int
    let skipped: Int
    let outputs: [ImageConversionOutput]

    /// The produced files in order. Preserved for callers that only need the URLs.
    var outputURLs: [URL] { outputs.map(\.outputURL) }
}

struct ImageConversionSession: Sendable {
    /// The system Downloads directory, or the temporary directory as a fallback.
    static var defaultDownloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    func convertAll(
        inputs: [ImageConversionInput],
        target: ImageConversionFormat,
        quality: Double = ImageConverter.defaultQuality,
        downloadsDirectory: URL,
        calendar: Calendar = .current,
        now: Date = Date()
    ) async -> ImageConversionSummary {
        let bitmapBaseName = ImageConversionNaming.bitmapBaseName(timestamp: now, calendar: calendar)
        let task = Task.detached(priority: .userInitiated) {
            convertAllSynchronously(
                inputs: inputs,
                target: target,
                quality: quality,
                downloadsDirectory: downloadsDirectory,
                bitmapBaseName: bitmapBaseName
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// File-only convenience preserved for callers that never handle bitmaps.
    func convertAll(
        fileURLs: [URL],
        target: ImageConversionFormat,
        quality: Double = ImageConverter.defaultQuality
    ) async -> ImageConversionSummary {
        await convertAll(
            inputs: fileURLs.map(ImageConversionInput.file),
            target: target,
            quality: quality,
            downloadsDirectory: Self.defaultDownloadsDirectory
        )
    }
}

private func convertAllSynchronously(
    inputs: [ImageConversionInput],
    target: ImageConversionFormat,
    quality: Double,
    downloadsDirectory: URL,
    bitmapBaseName: String
) -> ImageConversionSummary {
    let converter = ImageConverter()
    var converted = 0
    var skipped = 0
    var outputs: [ImageConversionOutput] = []

    for (inputIndex, input) in inputs.enumerated() {
        guard !Task.isCancelled else { break }
        switch input {
        case let .file(fileURL):
            guard ImageConverter.canDecodeFile(at: fileURL) else {
                skipped += 1
                continue
            }
            let outputURL = ImageConversionNaming.outputURL(forFileSource: fileURL, target: target)
            do {
                try converter.convertFile(at: fileURL, to: outputURL, format: target, quality: quality)
                converted += 1
                outputs.append(ImageConversionOutput(
                    inputIndex: inputIndex,
                    sourceName: fileURL.lastPathComponent,
                    sourceKind: .file,
                    outputURL: outputURL
                ))
            } catch {
                skipped += 1
            }
        case let .bitmap(data):
            guard ImageConverter.canDecodeData(data) else {
                skipped += 1
                continue
            }
            let outputURL = ImageConversionNaming.outputURL(
                forBitmapInDownloads: downloadsDirectory,
                baseName: bitmapBaseName,
                target: target
            )
            do {
                try converter.convert(data: data, to: outputURL, format: target, quality: quality)
                converted += 1
                // A bitmap has no source filename; the output's base name is the
                // most meaningful label ("Clipboard <timestamp>").
                outputs.append(ImageConversionOutput(
                    inputIndex: inputIndex,
                    sourceName: outputURL.deletingPathExtension().lastPathComponent,
                    sourceKind: .bitmap,
                    outputURL: outputURL
                ))
            } catch {
                skipped += 1
            }
        }
    }

    return ImageConversionSummary(converted: converted, skipped: skipped, outputs: outputs)
}
