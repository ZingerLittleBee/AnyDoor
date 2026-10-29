import AppKit

/// Owns the native destination choice for a non-overwriting independent export.
@MainActor
final class ClipboardFileExportPicker: NSObject, NSOpenSavePanelDelegate {
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
