import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageConversionFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    case heic
    case avif
    /// Encoded by the bundled libwebp — ImageIO decodes WebP but has no
    /// encoder, so `availableTargets()` (ImageIO-based) never lists it and the
    /// Quality-mode picker never offers it. Only Target Size's same-format
    /// path produces WebP output.
    case webp
    case tiff
    case gif
    case bmp
    case pdf
    case ico

    public var id: String { rawValue }

    var typeIdentifier: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .webp: return "org.webmproject.webp"
        case .tiff: return "public.tiff"
        case .gif: return "com.compuserve.gif"
        case .bmp: return "com.microsoft.bmp"
        case .pdf: return "com.adobe.pdf"
        case .ico: return "com.microsoft.ico"
        }
    }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .avif: return "avif"
        case .webp: return "webp"
        case .tiff: return "tiff"
        case .gif: return "gif"
        case .bmp: return "bmp"
        case .pdf: return "pdf"
        case .ico: return "ico"
        }
    }

    /// Lossy formats accept a quality parameter; lossless ones ignore it, so the
    /// UI only offers the quality slider for these.
    public var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .avif, .webp: return true
        case .png, .tiff, .gif, .bmp, .pdf, .ico: return false
        }
    }

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .webp: return "WebP"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .pdf: return "PDF"
        case .ico: return "ICO"
        }
    }

    /// Whether this runtime can encode the format. ImageIO formats depend on
    /// the system encoder set (e.g. AVIF needs an OS AV1 encoder); WebP is
    /// encoded by the bundled libwebp and is always available.
    var encoderAvailable: Bool {
        self == .webp || Self.availableTargets().contains(self)
    }

    /// The system UTType for this format, used to widen the screenshot Save As
    /// panel's allowed content types to the whitelist.
    public var utType: UTType? {
        UTType(typeIdentifier)
    }

    /// Resolves a Save As filename extension to a target format. The comparison is
    /// case-insensitive and understands the common JPEG spelling aliases (`jpg` /
    /// `jpeg`); any extension outside the whitelist falls back to PNG, so a plain
    /// `.png` save writes the original bytes with no re-encode.
    public static func forSaveExtension(_ ext: String) -> ImageConversionFormat {
        let normalized = ext.lowercased()
        if normalized == "jpg" || normalized == "jpeg" { return .jpeg }
        // The Save As pipeline encodes through ImageIO, which cannot write
        // WebP; a typed ".webp" falls back to PNG like any unknown extension.
        return allCases.first { $0.fileExtension == normalized && $0 != .webp } ?? .png
    }

    /// Target Size output format for a source container: same-format in/out.
    /// `nil` for containers Target Size cannot compress — they have neither an
    /// encoder quality knob nor a meaningful resize contract (GIF/TIFF/BMP/
    /// ICO/PDF). HEIF sources normalize to the HEIC encoder.
    static func targetSizeFormat(forSourceType typeIdentifier: String) -> ImageConversionFormat? {
        switch typeIdentifier {
        case ImageConversionFormat.jpeg.typeIdentifier: return .jpeg
        case ImageConversionFormat.heic.typeIdentifier, "public.heif": return .heic
        case ImageConversionFormat.avif.typeIdentifier: return .avif
        case ImageConversionFormat.webp.typeIdentifier: return .webp
        case ImageConversionFormat.png.typeIdentifier: return .png
        default: return nil
        }
    }

    public static func availableTargets() -> [ImageConversionFormat] {
        let identifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return availableTargets(encoderTypeIdentifiers: identifiers)
    }

    static func availableTargets(encoderTypeIdentifiers identifiers: [String]) -> [ImageConversionFormat] {
        let supported = Set(identifiers)
        return allCases.filter { supported.contains($0.typeIdentifier) }
    }
}
