import AppKit
import SwiftUI

/// Adapts `NSColorSampler`'s completion-handler API into `async`.
///
/// `NSColorSampler` presents the macOS system color-sampling loupe and must be
/// used on the main thread. The picked `NSColor` is converted to `Sendable`
/// values inside the completion handler so it never crosses an actor boundary.
@MainActor
enum ColorSampler {
    /// The result of one color-sampling session.
    enum Outcome: Sendable {
        /// The user picked a color: `hex` is `"#RRGGBB"`, `swatch` previews it.
        case picked(hex: String, swatch: Color)
        /// A color was picked but could not be represented in sRGB.
        case conversionFailed
        /// The user dismissed the loupe without picking (e.g. pressed Escape).
        case cancelled
    }

    /// Presents the system color loupe and waits for the user to pick a pixel
    /// or cancel.
    static func sample() async -> Outcome {
        await withCheckedContinuation { continuation in
            NSColorSampler().show { color in
                guard let color else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                // Derive both the hex string and the swatch from the same sRGB
                // representation, so the previewed swatch matches the value the
                // user pastes (the raw NSColor may be in a wider gamut).
                guard let hex = color.sRGBHexString,
                      let srgb = color.usingColorSpace(.sRGB) else {
                    continuation.resume(returning: .conversionFailed)
                    return
                }
                continuation.resume(
                    returning: .picked(hex: hex, swatch: Color(nsColor: srgb))
                )
            }
        }
    }
}
