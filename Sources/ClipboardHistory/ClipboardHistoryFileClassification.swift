import Foundation
import UniformTypeIdentifiers

enum ClipboardHistoryFileClassification {
    /// Classify references from metadata only, including files that are no
    /// longer reachable. Never open a video just to populate a history filter.
    static func facets(resourceType: String?, capturedPath: String) -> Set<ClipboardHistoryFacet> {
        let declaredType = resourceType.flatMap { UTType($0) }
        var facets: Set<ClipboardHistoryFacet> = [.file]
        if declaredType?.conforms(to: .image) == true {
            facets.insert(.image)
        }
        if isVideo(declaredType: declaredType, capturedPath: capturedPath) {
            facets.insert(.video)
        }
        return facets
    }

    private static func isVideo(declaredType: UTType?, capturedPath: String) -> Bool {
        if let declaredType, !declaredType.isDynamic,
           declaredType != .data, declaredType != .item {
            return declaredType.conforms(to: .movie) || declaredType.conforms(to: .video)
        }
        let suffix = URL(fileURLWithPath: capturedPath).pathExtension.lowercased()
        if let type = UTType(filenameExtension: suffix),
           type.conforms(to: .movie) || type.conforms(to: .video) {
            return true
        }
        // These common containers may have no registered UTI on a fresh Mac.
        return ["mkv", "webm"].contains(suffix)
    }
}
