import Foundation

extension ClipboardHistoryModule {
    /// Exports complete ordered file items to explicitly chosen destinations.
    /// Saving never creates a linked location or authorizes a pending download.
    public func exportFiles(_ entryID: ClipboardHistoryEntryID, to destinations: [URL]) async throws -> [URL] {
        let content = try await materialize(.init(entryID: entryID, purpose: .hostAction))
        let sources = content.items.flatMap(\.representations).compactMap { representation -> URL? in
            if case .file(let file) = representation { return file.currentURL }
            return nil
        }
        guard !sources.isEmpty, sources.count == destinations.count,
              destinations.allSatisfy(\.isFileURL),
              Set(destinations.map { $0.standardizedFileURL.path }).count == destinations.count else {
            throw ClipboardHistoryModuleError.invalidFileExport
        }
        for destination in destinations {
            if (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey])) != nil {
                throw ClipboardHistoryModuleError.fileExportCollision(destination)
            }
        }
        // The caller's chosen output is an ordinary independent file. All
        // sources have already passed complete-entry materialization above.
        return try await Task.detached(priority: .userInitiated) {
            for (source, destination) in zip(sources, destinations) {
                var coordinationError: NSError?
                var copyError: (any Error)?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordinationError) {
                    coordinatedURL in
                    do { try FileManager.default.copyItem(at: coordinatedURL, to: destination) }
                    catch { copyError = error }
                }
                if let error = coordinationError ?? copyError as NSError? { throw error }
            }
            return destinations
        }.value
    }
}
