import Foundation

/// The panel can resize freely; the image itself always remains aspect-fit.
/// A small amount of letterboxing keeps controls usable even for narrow captures.
enum PinnedImageLayout {
    static let minimumSize = CGSize(width: 180, height: 100)
    static let initialMaximumDimension: CGFloat = 360

    static func initialSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return minimumSize }
        let scale = min(1, initialMaximumDimension / max(imageSize.width, imageSize.height))
        return CGSize(
            width: max(minimumSize.width, imageSize.width * scale),
            height: max(minimumSize.height, imageSize.height * scale)
        )
    }
}
