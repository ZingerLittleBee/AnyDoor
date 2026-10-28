import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func reassociateFileLocation(_ request: ClipboardHistoryFileLocationReassociation) async throws -> ClipboardHistoryLinkedFileLocation {
        throw ClipboardHistoryModuleError.operationUnavailable
    }

    public func setFileLocationPaused(_ selection: ClipboardHistoryFileLocationSelection, paused: Bool) async throws {
        throw ClipboardHistoryModuleError.operationUnavailable
    }
}
