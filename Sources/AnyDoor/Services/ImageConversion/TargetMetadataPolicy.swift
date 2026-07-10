import CryptoKit
import Foundation
import ImageIO

/// The Target Size metadata policy (V1): preserve display-critical
/// information, remove ancillary metadata, and audit rather than trust.
///
/// Re-encoded candidates satisfy the policy by construction — they are built
/// from decoded pixels plus explicit display properties and never inherit the
/// source's metadata dictionary. Lossless pass-through applies the policy via
/// copy options, and only the audit decides whether the result qualifies.
enum TargetMetadataPolicy {
    static let version = 1

    /// Options for `CGImageDestinationCopyImageSource` that request the
    /// policy losslessly. Empirically JPEG honors this; HEIC may leave GPS
    /// behind and AVIF may reject the operation entirely — the audit, not the
    /// format name, decides.
    static func passThroughOptions() -> CFDictionary {
        let emptyMetadata = CGImageMetadataCreateMutable()
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: emptyMetadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        return options as CFDictionary
    }

    /// Capture-detail EXIF keys that must not survive into a Target Size
    /// output. Structural EXIF keys the encoder itself writes (pixel
    /// dimensions, color space) are legitimate and not listed.
    private static var forbiddenExifKeys: [CFString] { [
        kCGImagePropertyExifDateTimeOriginal,
        kCGImagePropertyExifDateTimeDigitized,
        kCGImagePropertyExifFNumber,
        kCGImagePropertyExifExposureTime,
        kCGImagePropertyExifISOSpeedRatings,
        kCGImagePropertyExifLensMake,
        kCGImagePropertyExifLensModel,
        kCGImagePropertyExifMakerNote,
        kCGImagePropertyExifUserComment,
    ] }

    /// Device/ownership TIFF keys that identify the capture device.
    private static var forbiddenTIFFKeys: [CFString] { [
        kCGImagePropertyTIFFMake,
        kCGImagePropertyTIFFModel,
        kCGImagePropertyTIFFDateTime,
        kCGImagePropertyTIFFArtist,
        kCGImagePropertyTIFFCopyright,
    ] }

    /// Whether a decoded candidate's property tree is free of ancillary
    /// metadata under this policy.
    static func ancillaryMetadataAbsent(in properties: [CFString: Any]) -> Bool {
        if properties[kCGImagePropertyGPSDictionary] != nil { return false }
        if properties[kCGImagePropertyIPTCDictionary] != nil { return false }
        if properties[kCGImagePropertyMakerAppleDictionary] != nil { return false }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for key in forbiddenExifKeys where exif[key] != nil { return false }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for key in forbiddenTIFFKeys where tiff[key] != nil { return false }
        }
        return true
    }
}

/// What a full audit of one final or pass-through candidate observed.
/// The engine compares this against the frozen configuration's expectations;
/// audit failure is never silently accepted.
struct CandidateAuditReport: Hashable, Sendable {
    var decodable: Bool
    var pixelDimensions: PixelDimensions?
    var ancillaryMetadataAbsent: Bool
    /// Raw `kCGImagePropertyOrientation` (1 when absent, the EXIF default).
    var orientation: UInt32
    var colorProfile: ImageColorProfileSignature?
    var hasAlpha: Bool
    var hasHDRGainMap: Bool
}

enum CandidateAuditor {
    /// Reopen encoded bytes and report what is actually inside them.
    static func audit(_ data: Data) -> CandidateAuditReport {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return CandidateAuditReport(
                decodable: false,
                pixelDimensions: nil,
                ancillaryMetadataAbsent: false,
                orientation: 1,
                colorProfile: nil,
                hasAlpha: false,
                hasHDRGainMap: false
            )
        }

        var hasHDRGainMap =
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        if #available(macOS 15.0, *), !hasHDRGainMap {
            hasHDRGainMap =
                CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        }

        return CandidateAuditReport(
            decodable: true,
            pixelDimensions: PixelDimensions(width: width, height: height),
            ancillaryMetadataAbsent: TargetMetadataPolicy.ancillaryMetadataAbsent(in: properties),
            orientation: (properties[kCGImagePropertyOrientation] as? UInt32)
                ?? (properties[kCGImagePropertyOrientation] as? Int).map(UInt32.init)
                ?? 1,
            colorProfile: ImageColorProfileSignature(image.colorSpace),
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            hasHDRGainMap: hasHDRGainMap
        )
    }
}
/// Stable, Sendable evidence for the decoded color space of a source or
/// candidate. Named ICC profiles must remain byte-identical; unprofiled spaces
/// fall back to matching their Core Graphics color model.
struct ImageColorProfileSignature: Hashable, Sendable {
    var model: String
    var name: String?
    var iccSHA256: String?

    init?(_ colorSpace: CGColorSpace?) {
        guard let colorSpace else { return nil }
        model = String(describing: colorSpace.model)
        name = colorSpace.name as String?
        iccSHA256 = colorSpace.copyICCData().map { data in
            SHA256.hash(data: data as Data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    static func matches(
        expected: ImageColorProfileSignature?,
        actual: ImageColorProfileSignature?
    ) -> Bool {
        switch (expected, actual) {
        case (nil, nil):
            return true
        case let (expected?, actual?):
            guard expected.model == actual.model else { return false }
            if let expectedICC = expected.iccSHA256 {
                return actual.iccSHA256 == expectedICC
            }
            if let expectedName = expected.name, let actualName = actual.name {
                return expectedName == actualName
            }
            return true
        default:
            return false
        }
    }
}
