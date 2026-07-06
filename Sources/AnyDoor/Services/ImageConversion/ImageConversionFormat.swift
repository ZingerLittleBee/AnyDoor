import Foundation
import ImageIO

enum ImageConversionFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    case heic
    case avif
    case tiff
    case gif
    case bmp
    case pdf
    case ico

    var id: String { rawValue }

    var typeIdentifier: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .tiff: return "public.tiff"
        case .gif: return "com.compuserve.gif"
        case .bmp: return "com.microsoft.bmp"
        case .pdf: return "com.adobe.pdf"
        case .ico: return "com.microsoft.ico"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .avif: return "avif"
        case .tiff: return "tiff"
        case .gif: return "gif"
        case .bmp: return "bmp"
        case .pdf: return "pdf"
        case .ico: return "ico"
        }
    }

    /// Lossy formats accept a quality parameter; lossless ones ignore it, so the
    /// UI only offers the quality slider for these.
    var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .avif: return true
        case .png, .tiff, .gif, .bmp, .pdf, .ico: return false
        }
    }

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        case .pdf: return "PDF"
        case .ico: return "ICO"
        }
    }

    static func availableTargets() -> [ImageConversionFormat] {
        let identifiers = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return availableTargets(encoderTypeIdentifiers: identifiers)
    }

    static func availableTargets(encoderTypeIdentifiers identifiers: [String]) -> [ImageConversionFormat] {
        let supported = Set(identifiers)
        return allCases.filter { supported.contains($0.typeIdentifier) }
    }
}
