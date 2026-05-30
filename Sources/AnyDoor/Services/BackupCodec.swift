import Foundation

enum BackupCodecError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

/// Serializes `BackupSnapshot` to/from pretty-printed JSON with ISO8601 dates.
/// The single place future schema migrations will live.
enum BackupCodec {

    static func encode(_ snapshot: BackupSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> BackupSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(BackupSnapshot.self, from: data)
        guard snapshot.schemaVersion <= BackupSnapshot.currentSchemaVersion else {
            throw BackupCodecError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        return snapshot
    }
}
