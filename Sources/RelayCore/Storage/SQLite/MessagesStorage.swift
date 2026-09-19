import Foundation

public final class MessagesStorage: DatabaseStatusProviding, Sendable {
    public let conversations: SQLiteConversationStore
    public let messages: SQLiteMessageStore
    public let media: SQLiteMediaStore

    private let executor: SQLiteExecutor

    public init(path: String, attachmentDirectory: String? = nil) {
        let executor = SQLiteExecutor(path: path)
        self.executor = executor
        conversations = SQLiteConversationStore(executor: executor)
        messages = SQLiteMessageStore(executor: executor)
        let directory = attachmentDirectory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: path)
                .deletingLastPathComponent()
                .appendingPathComponent("Attachments", isDirectory: true)
        media = SQLiteMediaStore(executor: executor, attachmentDirectory: directory)
    }

    public func databaseStatus() async -> DatabaseStatus {
        do {
            return try await executor.run { database in
                _ = try database.firstText("SELECT guid FROM chat LIMIT 1")
                return DatabaseStatus(
                    ready: true,
                    identity: try database.identity(),
                    error: nil
                )
            }
        } catch {
            return DatabaseStatus(ready: false, identity: nil, error: String(describing: error))
        }
    }

    public func shutdown() async throws {
        try await executor.shutdown()
    }
}
