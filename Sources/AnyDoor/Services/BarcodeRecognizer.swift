import CoreGraphics
import Foundation
import Vision

/// Decodes QR codes in a still image using the macOS Vision framework.
///
/// Restricted to QR symbology only; other barcode types (EAN, Code 128, Aztec,
/// ...) are ignored even if present in the image.
enum BarcodeRecognizer {
    /// Decodes every QR code in `image`. Returns one string per code, ordered
    /// top-to-bottom by bounding-box position. An empty array means no QR code
    /// was found (not an error).
    static func scan(_ image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNDetectBarcodesRequest()
                    request.symbologies = [.qr]

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])

                    let observations = request.results ?? []
                    // Vision's normalized coordinate space has Y increasing upward,
                    // so the top-most code has the largest boundingBox.maxY.
                    let payloads = observations
                        .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                        .compactMap { observation -> String? in
                            guard let value = observation.payloadStringValue,
                                  !value.isEmpty else { return nil }
                            return value
                        }
                    continuation.resume(returning: payloads)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
