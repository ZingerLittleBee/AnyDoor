import ClipboardHistory
import Foundation
import PluginInterface
import UniformTypeIdentifiers

enum ClipboardPluginPayloadMapper {
    static func payload(
        from materialization: ClipboardHistoryMaterialization,
        displayName: String
    ) -> PluginClipboardPayload? {
        let representations = materialization.items.flatMap(\.representations)
        if let bitmap = representations.lazy.compactMap({ representation
            -> Data? in
            guard case .data(let typeIdentifier, let data) = representation,
                UTType(typeIdentifier)?.conforms(to: .image) == true
            else {
                return nil
            }
            return data
        }).first {
            return .bitmap(data: bitmap, displayName: displayName)
        }

        let files = representations.compactMap { representation -> URL? in
            guard case .file(let file) = representation else { return nil }
            return file.currentURL
        }
        return files.isEmpty ? nil : .files(files)
    }
}
