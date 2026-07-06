import Foundation

/// One conversion source: either an on-disk file (output beside it) or an
/// in-memory bitmap such as a pasted screenshot (output to Downloads).
enum ImageConversionInput: Sendable {
    case file(URL)
    case bitmap(Data)
}

struct ImageConversionSummary: Equatable, Sendable {
    let converted: Int
    let skipped: Int
    let outputURLs: [URL]
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
        return await Task.detached(priority: .userInitiated) {
            convertAllSynchronously(
                inputs: inputs,
                target: target,
                quality: quality,
                downloadsDirectory: downloadsDirectory,
                bitmapBaseName: bitmapBaseName
            )
        }.value
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
    var outputURLs: [URL] = []

    for input in inputs {
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
                outputURLs.append(outputURL)
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
                outputURLs.append(outputURL)
            } catch {
                skipped += 1
            }
        }
    }

    return ImageConversionSummary(converted: converted, skipped: skipped, outputURLs: outputURLs)
}
