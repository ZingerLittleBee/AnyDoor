import AppKit

/// Owns the native destination choice for a non-overwriting independent export.
@MainActor
final class ClipboardFileExportPicker: NSObject, NSOpenSavePanelDelegate {
    func destinations(for sources: [URL], in directory: URL) throws -> [URL] {
        var usedNames = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path).map { $0.lowercased() })
        return sources.map { source in
            let name = source.lastPathComponent
            let stem = source.deletingPathExtension().lastPathComponent
            let ext = source.pathExtension
            var candidate = name
            var suffix = 2
            while !usedNames.insert(candidate.lowercased()).inserted {
                candidate = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
                suffix += 1
            }
            return directory.appendingPathComponent(candidate)
        }
    }

    func chooseDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = L(.clipboardActionSaveFiles)
        panel.nameFieldStringValue = suggestedName
        panel.delegate = self
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func validateDestination(_ url: URL) throws {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return
        }
        throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteFileExists.rawValue,
            userInfo: [NSLocalizedDescriptionKey: L(.clipboardFileExportCollision)])
    }

    // AppKit asks this before its replacement confirmation. Keep the panel
    // open instead of offering Replace, which an independent export refuses.
    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        guard okFlag, let panel = sender as? NSSavePanel, let directory = panel.directoryURL else { return filename }
        let path = (filename as NSString).expandingTildeInPath
        let destination = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        do {
            try validateDestination(destination)
            panel.message = ""
            return filename
        } catch {
            panel.message = error.localizedDescription
            return nil
        }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        try validateDestination(url)
    }
}
