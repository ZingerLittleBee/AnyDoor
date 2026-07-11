import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a basket item cannot convert under the current configuration.
enum ImageConversionPreflightIssue: Error, Hashable, Sendable {
    case sourceMissing
    case undecodable
    /// PDF input stays out of scope even when Image I/O could rasterize it.
    case pdfInput
    /// Target Size rejects Multi-Image Sources; Quality mode never raises this.
    case multiImageUnsupported
    case encoderUnavailable(ImageConversionFormat)
    /// Target Size keeps the source format, and this source's container has no
    /// size-compression strategy (GIF/TIFF/BMP/ICO). Quality mode never raises
    /// this.
    case targetSizeUnsupportedFormat
}

/// Lightweight inspection of one source. Preflight never creates conversion
/// candidates; it only reads container properties.
struct ImageConversionPreflight: Hashable, Sendable {
    /// Stored pixel dimensions of the first image (not orientation-swapped;
    /// the encode path normalizes orientation itself).
    var dimensions: PixelDimensions
    var frameCount: Int
    /// Quality mode converts only the first image of a Multi-Image Source
    /// and must say so in the basket before the run.
    var firstFrameOnly: Bool
    var hasAlpha: Bool
    var hasHDRGainMap: Bool
    /// The selected target cannot encode this source's alpha, so the shared
    /// Transparency Background control applies to this item.
    var requiresTransparencyBackground: Bool
    var sourceByteCount: Int64?
    /// The same-format Target Size output resolved from the source container.
    /// Populated only by a same-format-resolving inspector; nil in Quality mode.
    var sameFormatTarget: ImageConversionFormat?
}

/// Per-mode source inspection over Image I/O.
struct ImageIOSourceInspector: Sendable {
    /// Target Size rejects Multi-Image Sources; Quality keeps the original
    /// first-frame contract. The caller maps the Conversion Mode to this flag
    /// so the inspector stays independent of preference types.
    var rejectsMultiImage: Bool
    /// Target Size resolves its output format from the source container
    /// (same-format in/out) and ignores the `target` parameter; Quality mode
    /// keeps the explicit target.
    var resolvesSameFormatTarget: Bool = false

    func preflight(
        input: ImageConversionInput,
        target: ImageConversionFormat?
    ) -> Result<ImageConversionPreflight, ImageConversionPreflightIssue> {
        switch input {
        case .file(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure(.sourceMissing)
            }
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
               type.conforms(to: .pdf) {
                return .failure(.pdfInput)
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return .failure(.undecodable)
            }
            let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init)
            return inspect(source, target: target, sourceByteCount: byteCount)

        case .bitmap(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return .failure(.undecodable)
            }
            return inspect(source, target: target, sourceByteCount: Int64(data.count))
        }
    }

    private func inspect(
        _ source: CGImageSource,
        target: ImageConversionFormat?,
        sourceByteCount: Int64?
    ) -> Result<ImageConversionPreflight, ImageConversionPreflightIssue> {
        if let type = CGImageSourceGetType(source) as String?,
           UTType(type)?.conforms(to: .pdf) == true {
            return .failure(.pdfInput)
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount >= 1 else { return .failure(.undecodable) }

        // Same-format resolution precedes the multi-image check so an animated
        // GIF reports the format contract, not the frame-count detail.
        let effectiveTarget: ImageConversionFormat
        if resolvesSameFormatTarget {
            guard let type = CGImageSourceGetType(source) as String?,
                  let resolved = ImageConversionFormat.targetSizeFormat(forSourceType: type) else {
                return .failure(.targetSizeUnsupportedFormat)
            }
            effectiveTarget = resolved
        } else if let target {
            effectiveTarget = target
        } else {
            // A Quality-mode caller must supply its target explicitly.
            return .failure(.undecodable)
        }

        if frameCount > 1, rejectsMultiImage {
            return .failure(.multiImageUnsupported)
        }

        guard ImageConversionFormat.availableTargets().contains(effectiveTarget) else {
            return .failure(.encoderUnavailable(effectiveTarget))
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return .failure(.undecodable)
        }

        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        var hasHDRGainMap =
            CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        if #available(macOS 15.0, *), !hasHDRGainMap {
            hasHDRGainMap =
                CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        }

        return .success(ImageConversionPreflight(
            dimensions: PixelDimensions(width: width, height: height),
            frameCount: frameCount,
            firstFrameOnly: frameCount > 1,
            hasAlpha: hasAlpha,
            hasHDRGainMap: hasHDRGainMap,
            requiresTransparencyBackground: hasAlpha
                && !ImageIOCapabilityCache.targetPreservesAlpha(effectiveTarget),
            sourceByteCount: sourceByteCount,
            sameFormatTarget: resolvesSameFormatTarget ? effectiveTarget : nil
        ))
    }
}
