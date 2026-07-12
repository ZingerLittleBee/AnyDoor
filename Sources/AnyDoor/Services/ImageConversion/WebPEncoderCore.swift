import Foundation
import libwebp

/// Thin wrapper over the bundled libwebp encoder (ImageIO decodes WebP but
/// cannot encode it). Input is straight-alpha RGBA8 in sRGB; the caller owns
/// color conversion and orientation baking.
enum WebPEncoderCore {
    enum WebPEncodeError: Error {
        case invalidConfiguration
        case dimensionsUnsupported
        case encodingFailed
    }

    /// libwebp's hard per-side limit (14 bits).
    static let maxPixelsPerSide = 16_383

    /// Encode one still image at a whole-percent quality (1–100).
    /// `hasAlpha: false` imports the buffer as RGBX so a fully opaque image
    /// never grows an alpha chunk.
    static func encode(
        rgba: [UInt8],
        width: Int,
        height: Int,
        quality: Int,
        hasAlpha: Bool
    ) throws -> Data {
        guard width > 0, height > 0,
              width <= maxPixelsPerSide, height <= maxPixelsPerSide,
              rgba.count == width * height * 4 else {
            throw WebPEncodeError.dimensionsUnsupported
        }

        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else {
            throw WebPEncodeError.invalidConfiguration
        }
        config.quality = Float(min(max(quality, 1), 100))
        guard WebPValidateConfig(&config) != 0 else {
            throw WebPEncodeError.invalidConfiguration
        }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else {
            throw WebPEncodeError.encodingFailed
        }
        defer { WebPPictureFree(&picture) }
        picture.width = Int32(width)
        picture.height = Int32(height)
        picture.use_argb = 1

        let stride = Int32(width * 4)
        let imported = rgba.withUnsafeBufferPointer { buffer in
            hasAlpha
                ? WebPPictureImportRGBA(&picture, buffer.baseAddress, stride)
                : WebPPictureImportRGBX(&picture, buffer.baseAddress, stride)
        }
        guard imported != 0 else { throw WebPEncodeError.encodingFailed }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        picture.writer = WebPMemoryWrite

        let encoded = withUnsafeMutablePointer(to: &writer) { writerPointer in
            picture.custom_ptr = UnsafeMutableRawPointer(writerPointer)
            return WebPEncode(&config, &picture) != 0
        }
        guard encoded, let bytes = writer.mem, writer.size > 0 else {
            throw WebPEncodeError.encodingFailed
        }
        return Data(bytes: bytes, count: writer.size)
    }
}
