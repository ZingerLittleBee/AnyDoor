import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ClipboardHistoryModule {
    struct CanonicalIdentity: Equatable {
        static let encodingVersion: UInt64 = 1

        let fingerprint: Data
        let canonicalByteCount: Int
        let structure: Data
        let payloadDigests: [Data]

        init(
            snapshot: PasteboardSnapshot,
            fingerprintDigest: @Sendable (Data) -> Data
        ) throws {
            var canonical = LengthPrefixedEncoding()
            var structure = LengthPrefixedEncoding()
            var payloadDigests: [Data] = []

            canonical.append("AnyDoor Clipboard Entry")
            canonical.append(Self.encodingVersion)
            canonical.append(UInt64(snapshot.items.count))
            structure.append("AnyDoor Clipboard Entry")
            structure.append(Self.encodingVersion)
            structure.append(UInt64(snapshot.items.count))

            for (itemIndex, item) in snapshot.items.enumerated() {
                canonical.append("item")
                canonical.append(UInt64(itemIndex))
                structure.append("item")
                structure.append(UInt64(itemIndex))

                let representations = try item.representations.enumerated()
                    .map { offset, representation in
                        try CanonicalRepresentation(
                            representation,
                            originalOffset: offset
                        )
                    }
                    .sorted { lhs, rhs in
                        if lhs.typeIdentifier != rhs.typeIdentifier {
                            return lhs.typeIdentifier.utf8
                                .lexicographicallyPrecedes(
                                    rhs.typeIdentifier.utf8
                                )
                        }
                        return lhs.originalOffset < rhs.originalOffset
                    }
                canonical.append(UInt64(representations.count))
                structure.append(UInt64(representations.count))

                for representation in representations {
                    canonical.append(representation.kind)
                    canonical.append(representation.typeIdentifier)
                    canonical.append(representation.metadata)
                    canonical.append(representation.payload)

                    structure.append(representation.kind)
                    structure.append(representation.typeIdentifier)
                    structure.append(representation.metadata)
                    structure.append(UInt64(representation.payload.count))
                    payloadDigests.append(Self.sha256(representation.payload))
                }
            }

            fingerprint = fingerprintDigest(canonical.data)
            canonicalByteCount = canonical.data.count
            self.structure = structure.data
            self.payloadDigests = payloadDigests
        }

        static func sha256(_ data: Data) -> Data {
            Data(SHA256.hash(data: data))
        }
    }

    private struct CanonicalRepresentation {
        let kind: String
        let typeIdentifier: String
        let metadata: Data
        let payload: Data
        let originalOffset: Int

        init(
            _ representation: PasteboardSnapshot.Representation,
            originalOffset: Int
        ) throws {
            self.originalOffset = originalOffset
            switch representation {
            case .text(let typeIdentifier, let value):
                kind = typeIdentifier == "public.url" ? "url" : "text"
                self.typeIdentifier = typeIdentifier
                metadata = Data()
                payload = Data(value.utf8)
            case .data(let typeIdentifier, let value):
                kind = "richText"
                self.typeIdentifier = typeIdentifier
                metadata = Data()
                payload = value
            case .bitmap(let png, _, let isScreenshot):
                kind = "bitmap"
                typeIdentifier = UTType.png.identifier
                metadata = try Self.bitmapMetadata(
                    from: png,
                    isScreenshot: isScreenshot
                )
                payload = png
            case .file(let reference):
                kind = "fileReference"
                typeIdentifier = "public.file-url"
                metadata = Data()
                payload = Data(
                    URL(fileURLWithPath: reference.capturedPath)
                        .standardizedFileURL.path.utf8
                )
            case .color(_, let normalizedValue):
                kind = "color"
                typeIdentifier = "com.apple.cocoa.pasteboard.color"
                metadata = Data()
                payload = Data(normalizedValue.utf8)
            }
        }

        private static func bitmapMetadata(
            from png: Data,
            isScreenshot: Bool
        ) throws -> Data {
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw ClipboardHistoryModuleError.storageFailure
            }

            var encoding = LengthPrefixedEncoding()
            encoding.append(isScreenshot ? UInt64(1) : UInt64(0))
            encoding.append(UInt64(image.width))
            encoding.append(UInt64(image.height))
            encoding.append(UInt64(image.bitsPerComponent))
            encoding.append(UInt64(image.bitsPerPixel))
            encoding.append(UInt64(image.alphaInfo.rawValue))
            encoding.append(UInt64(image.bitmapInfo.rawValue))
            if let colorSpace = image.colorSpace,
                let profile = colorSpace.copyICCData()
            {
                encoding.append(profile as Data)
            } else {
                encoding.append(Data())
            }
            return encoding.data
        }
    }
}

private struct LengthPrefixedEncoding {
    private(set) var data = Data()

    mutating func append(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func append(_ value: UInt64) {
        var bigEndian = value.bigEndian
        append(
            withUnsafeBytes(of: &bigEndian) { bytes in
                Data(bytes)
            }
        )
    }

    mutating func append(_ value: Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            data.append(contentsOf: bytes)
        }
        data.append(value)
    }
}
