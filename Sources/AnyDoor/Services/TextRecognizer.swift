import CoreGraphics
import Foundation
import Vision

/// Recognizes text in a still image using the macOS Vision framework.
enum TextRecognizer {
    struct Configuration: Equatable, Sendable {
        let automaticallyDetectsLanguage: Bool
        let recognitionLanguages: [String]
    }

    static let defaultConfiguration = Configuration(
        automaticallyDetectsLanguage: true,
        recognitionLanguages: ["zh-Hans", "zh-Hant", "en-US"]
    )

    /// Recognizes text in `image`. Returns one string per recognized text block,
    /// ordered top-to-bottom. An empty array means no text was found (not an error).
    static func recognize(_ image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let configuration = defaultConfiguration
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.automaticallyDetectsLanguage = configuration.automaticallyDetectsLanguage
                    request.recognitionLanguages = configuration.recognitionLanguages

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])

                    let observations = request.results ?? []
                    // Vision's normalized coordinate space has Y increasing upward,
                    // so the top-most block has the largest boundingBox.maxY.
                    let lines = observations
                        .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                        .compactMap { $0.topCandidates(1).first?.string }
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
