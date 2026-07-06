import Foundation

struct ImageConversionSummary: Equatable, Sendable {
    let converted: Int
    let skipped: Int
    let outputURLs: [URL]
}

struct ImageConversionSession: Sendable {
    func convertAll(
        fileURLs: [URL],
        target: ImageConversionFormat,
        quality: Double = ImageConverter.defaultQuality
    ) async -> ImageConversionSummary {
        await Task.detached(priority: .userInitiated) {
            convertAllSynchronously(fileURLs: fileURLs, target: target, quality: quality)
        }.value
    }
}

private func convertAllSynchronously(
    fileURLs: [URL],
    target: ImageConversionFormat,
    quality: Double
) -> ImageConversionSummary {
    let converter = ImageConverter()
    var converted = 0
    var skipped = 0
    var outputURLs: [URL] = []

    for fileURL in fileURLs {
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
    }

    return ImageConversionSummary(converted: converted, skipped: skipped, outputURLs: outputURLs)
}
