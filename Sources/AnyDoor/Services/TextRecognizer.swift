import CoreGraphics
import Foundation
import Vision

/// Recognizes text in a still image using the macOS Vision framework.
enum TextRecognizer {
    /// Recognizes text in `image`. Returns one string per recognized text block,
    /// ordered top-to-bottom. An empty array means no text was found (not an error).
    static func recognize(_ image: CGImage) async throws -> [String] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = [
            Locale.Language(identifier: "zh-Hans"),
            Locale.Language(identifier: "en-US"),
        ]

        let observations = try await request.perform(on: image)

        // Vision's normalized coordinate space has Y increasing upward, so the
        // top-most text block has the largest topLeft.y.
        return observations
            .sorted { $0.topLeft.y > $1.topLeft.y }
            .compactMap { $0.topCandidates(1).first?.string }
    }
}
