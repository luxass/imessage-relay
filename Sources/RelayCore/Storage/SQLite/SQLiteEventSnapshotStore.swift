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

    func snapshot(expectedFileIdentity: String? = nil) async throws -> SnapshotResult {
        try Task.checkCancellation()
        return try await executor.run { database in
            try Self.readSnapshot(
                database: database,
                expectedFileIdentity: expectedFileIdentity
            )
        }
    }

    func incrementalBatch(
        positions: IncrementalPositions,
        limit: Int,
        expectedFileIdentity: String
    ) async throws -> GenerationRead<IncrementalBatch> {
        try Task.checkCancellation()
        return try await executor.run { database in
            guard Self.isExpectedGeneration(database, expectedFileIdentity) else {
                return .databaseChanged
            }
            return .value(try Self.incrementalBatch(
                database: database,
                positions: positions,
                limit: limit
            ))
        }
    }

    func targetedBatch(
        after rowID: Int64,
        limit: Int,
        expectedFileIdentity: String
    ) async throws -> GenerationRead<TargetedBatch> {
        try Task.checkCancellation()
        return try await executor.run { database in
            guard Self.isExpectedGeneration(database, expectedFileIdentity) else {
                return .databaseChanged
            }
            return .value(try Self.targetedStateChanges(
                database: database,
                after: rowID,
                limit: limit
            ))
        }
    }

    func refreshMessageCandidates(
        rowIDs: [Int64],
        expectedFileIdentity: String
    ) async throws -> GenerationRead<[MessageCandidate]> {
        guard !rowIDs.isEmpty else { return .value([]) }
        return try await executor.run { database in
            guard Self.isExpectedGeneration(database, expectedFileIdentity) else {
                return .databaseChanged
            }
            return .value(try Self.refreshMessageCandidates(database: database, rowIDs: rowIDs))
        }
    }

    func refreshMedia(
        _ keys: [MediaKey],
        expectedFileIdentity: String
    ) async throws -> GenerationRead<[ObservedMedia]> {
        guard !keys.isEmpty else { return .value([]) }
        return try await executor.run { database in
            guard Self.isExpectedGeneration(database, expectedFileIdentity) else {
                return .databaseChanged
            }
            return .value(try Self.refreshMedia(database: database, keys: keys))
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

    private static func readSnapshot(
        database: SQLiteDatabase,
        expectedFileIdentity: String?
    ) throws -> SnapshotResult {
        guard (try? database.fileIdentity()) == database.connectionFileIdentity,
              expectedFileIdentity == nil
                || database.connectionFileIdentity == expectedFileIdentity else {
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
                media: media(database: database),
                positions: positions(database: database)
            )
        }
        guard (try? database.fileIdentity()) == database.connectionFileIdentity else {
            return .databaseChanged
        }
        return .snapshot(snapshot)
    }

    private static func isExpectedGeneration(
        _ database: SQLiteDatabase,
        _ expectedFileIdentity: String
    ) -> Bool {
        database.connectionFileIdentity == expectedFileIdentity
            && (try? database.fileIdentity()) == expectedFileIdentity
    }
}
