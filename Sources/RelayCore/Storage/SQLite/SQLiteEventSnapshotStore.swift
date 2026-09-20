import Darwin
import Foundation

final class SQLiteEventSnapshotStore: Sendable {
    let path: String
    private let executor: SQLiteExecutor
    private let attachmentDirectory: URL

    init(path: String, attachmentDirectory: String) {
        self.path = path
        executor = SQLiteExecutor(path: path)
        self.attachmentDirectory = URL(fileURLWithPath: attachmentDirectory).standardizedFileURL
    }

    func snapshot() async throws -> SnapshotResult {
        try Task.checkCancellation()
        return try await executor.run { database in
            try Self.readSnapshot(database: database)
        }
    }

    func databaseState() async throws -> DatabaseState? {
        try await executor.run { database in
            guard let fileIdentity = try? database.fileIdentity(),
                  fileIdentity == database.connectionFileIdentity else { return nil }
            return try DatabaseState(
                fileIdentity: fileIdentity,
                dataVersion: database.dataVersion()
            )
        }
    }

    func availableMedia(_ media: some Sequence<ObservedMedia>) -> Set<MediaKey> {
        let attachmentDirectory = attachmentDirectory
        return Set(media.compactMap { value in
            guard let path = value.path else { return nil }
            let expanded = (path as NSString).expandingTildeInPath
            guard let opened = openRegularFile(path: expanded, within: attachmentDirectory) else {
                return nil
            }
            close(opened.descriptor)
            return value.key
        })
    }

    func resetDatabaseConnection() async throws {
        try await executor.resetDatabase()
    }

    func shutdown() async throws {
        try await executor.shutdown()
    }

    private static func readSnapshot(database: SQLiteDatabase) throws -> SnapshotResult {
        guard (try? database.fileIdentity()) == database.connectionFileIdentity else {
            return .databaseChanged
        }
        let dataVersion = try database.dataVersion()
        let snapshot = try database.withReadTransaction {
            try Snapshot(
                databaseIdentity: database.identity(),
                fileIdentity: database.connectionFileIdentity,
                dataVersion: dataVersion,
                messages: messages(database: database),
                reactions: reactions(database: database),
                media: media(database: database)
            )
        }
        guard (try? database.fileIdentity()) == database.connectionFileIdentity else {
            return .databaseChanged
        }
        return .snapshot(snapshot)
    }
}
