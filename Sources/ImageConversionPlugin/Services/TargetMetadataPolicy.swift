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
///
/// V2: HEIF structural tile tags are recognized as non-ancillary, the
/// pass-through rewrite preserves orientation, and a policy-clean source that
/// already fits the target is emitted unchanged.
enum TargetMetadataPolicy {
    static let version = 2

    /// Options for `CGImageDestinationCopyImageSource` that request the
    /// policy losslessly. Empirically JPEG honors this; HEIC may leave GPS
    /// behind and AVIF may reject the operation entirely — the audit, not the
    /// format name, decides. Replacing the metadata also drops the EXIF
    /// orientation tag, so a non-default source orientation must be re-stated
    /// explicitly or the copy displays wrongly rotated.
    static func passThroughOptions(orientation: UInt32?) -> CFDictionary {
        let emptyMetadata = CGImageMetadataCreateMutable()
        var options: [CFString: Any] = [
            kCGImageDestinationMetadata: emptyMetadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        if let orientation, orientation != 1 {
            options[kCGImageDestinationOrientation] = orientation
        }
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
        kCGImagePropertyTIFFDocumentName,
        kCGImagePropertyTIFFImageDescription,
        kCGImagePropertyTIFFSoftware,
        kCGImagePropertyTIFFHostComputer,
    ] }

    /// Free-form PNG text chunks are ancillary and may carry ownership,
    /// workflow, or private user comments.
    private static var forbiddenPNGKeys: [CFString] { [
        kCGImagePropertyPNGAuthor,
        kCGImagePropertyPNGComment,
        kCGImagePropertyPNGDescription,
        kCGImagePropertyPNGTitle,
    ] }

    /// Whether a decoded candidate's property tree is free of ancillary
    /// metadata under this policy.
    static func ancillaryMetadataAbsent(
        in properties: [CFString: Any],
        hasForbiddenMetadataTags: Bool = false,
        hasEmbeddedThumbnails: Bool = false
    ) -> Bool {
        if hasForbiddenMetadataTags || hasEmbeddedThumbnails { return false }
        if properties[kCGImagePropertyGPSDictionary] != nil { return false }
        if properties[kCGImagePropertyIPTCDictionary] != nil { return false }
        if properties[kCGImagePropertyMakerAppleDictionary] != nil { return false }
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            for key in forbiddenExifKeys where exif[key] != nil { return false }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            for key in forbiddenTIFFKeys where tiff[key] != nil { return false }
        }
        if let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            for key in forbiddenPNGKeys where png[key] != nil { return false }
        }
        return true
    }

    /// Image I/O exposes structural EXIF fields through `CGImageMetadata` even
    /// for a clean re-encode. Reject every tag except the small display/shape
    /// set the encoder may synthesize itself.
    static func metadataContainsAncillaryTags(_ metadata: CGImageMetadata?) -> Bool {
        guard let metadata,
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else {
            return false
        }
        let allowedTags: Set<String> = [
            "exif:ColorSpace",
            "exif:PixelXDimension",
            "exif:PixelYDimension",
            "tiff:ImageLength",
            "tiff:ImageWidth",
            "tiff:Orientation",
            "tiff:ResolutionUnit",
            "tiff:XResolution",
            "tiff:YResolution",
            // HEIF grid tiling geometry; ImageIO surfaces these for every
            // HEIC on macOS 26, including its own fresh encodes.
            "tiff:TileLength",
            "tiff:TileWidth",
        ]
        return tags.contains { tag in
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else {
                return true
            }
            return !allowedTags.contains("\(prefix):\(name)")
        }
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
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let hasForbiddenMetadataTags = TargetMetadataPolicy.metadataContainsAncillaryTags(metadata)
        let containerProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let hasEmbeddedThumbnails = {
            guard let thumbnails = containerProperties?[kCGImagePropertyThumbnailImages] else { return false }
            if let array = thumbnails as? [Any] { return !array.isEmpty }
            return true
        }()

        return CandidateAuditReport(
            decodable: true,
            pixelDimensions: PixelDimensions(width: width, height: height),
            ancillaryMetadataAbsent: TargetMetadataPolicy.ancillaryMetadataAbsent(
                in: properties,
                hasForbiddenMetadataTags: hasForbiddenMetadataTags,
                hasEmbeddedThumbnails: hasEmbeddedThumbnails
            ),
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
