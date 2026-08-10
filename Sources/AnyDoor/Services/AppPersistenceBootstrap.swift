import Foundation
import OSLog
import SwiftData

private let logger = Logger(
    subsystem: "dev.bybee.AnyDoor",
    category: "persistence-bootstrap"
)

/// Opens the production SwiftData store only after the legacy clipboard
/// snapshot is safe. If snapshot preparation fails, the rest of the app uses
/// an isolated in-memory container while Clipboard Settings offers Retry.
@MainActor
struct AppPersistenceBootstrap {
    let modelContainer: ModelContainer
    let isRecoveryMode: Bool
    let migrationPreparation:
        @MainActor () async throws -> ClipboardHistoryMigrationPreparation

    static func make(
        schema: Schema,
        storeURL: URL,
        prepareLegacySnapshot:
            @escaping @MainActor () throws -> Void,
        requestRelaunch: @escaping @MainActor () async throws -> Void
    ) throws -> AppPersistenceBootstrap {
        do {
            try prepareLegacySnapshot()
        } catch {
            logger.error("Legacy snapshot preparation failed: \(error)")
            let recoveryContainer = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(
                    isStoredInMemoryOnly: true
                )
            )
            return AppPersistenceBootstrap(
                modelContainer: recoveryContainer,
                isRecoveryMode: true,
                migrationPreparation: {
                    try prepareLegacySnapshot()
                    try await requestRelaunch()
                    return .suspendForRelaunch
                }
            )
        }

        let productionContainer = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(url: storeURL)
        )
        return AppPersistenceBootstrap(
            modelContainer: productionContainer,
            isRecoveryMode: false,
            migrationPreparation: { .proceed }
        )
    }
}
