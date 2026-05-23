import CoreGraphics
import Foundation
import Vision

/// Recognizes text in a still image using the macOS Vision framework.
enum TextRecognizer {
    /// Recognizes text in `image`. Returns one string per recognized text block,
    /// ordered top-to-bottom. An empty array means no text was found (not an error).
    static func recognize(_ image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.automaticallyDetectsLanguage = false
                    request.recognitionLanguages = ["zh-Hans", "en-US"]

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
