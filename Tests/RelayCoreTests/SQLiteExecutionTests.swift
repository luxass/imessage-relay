import Foundation
import SQLite3
import Testing

@testable import RelayCore

@Test
func sqliteStatementRejectsMissingAndOutOfRangeBindings() throws {
    var connection: OpaquePointer?
    #expect(sqlite3_open(":memory:", &connection) == SQLITE_OK)
    let opened = try #require(connection)
    defer { sqlite3_close(opened) }

    #expect(throws: SQLiteStorageError.self) {
        _ = try SQLiteStatement(connection: opened, sql: "SELECT FROM")
    }

    let missing = try SQLiteStatement(connection: opened, sql: "SELECT ?1, ?2")
    try missing.bind(Int64(1), at: 1)
    #expect(throws: SQLiteStorageError.self) {
        _ = try missing.step()
    }
    #expect(missing.finalize() == nil)

    let outOfRange = try SQLiteStatement(connection: opened, sql: "SELECT ?1")
    #expect(throws: SQLiteStorageError.self) {
        try outOfRange.bind(Int64(1), at: 2)
    }
    #expect(outOfRange.finalize() == nil)
}

@Test
func sqliteStatementReportsBusyInsteadOfTreatingItAsCompletion() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-sqlite-busy-\(UUID().uuidString).db")
        .path
    defer { try? FileManager.default.removeItem(atPath: path) }

    var writer: OpaquePointer?
    var reader: OpaquePointer?
    #expect(sqlite3_open(path, &writer) == SQLITE_OK)
    #expect(sqlite3_open(path, &reader) == SQLITE_OK)
    let openedWriter = try #require(writer)
    let openedReader = try #require(reader)
    defer {
        sqlite3_exec(openedWriter, "ROLLBACK", nil, nil, nil)
        sqlite3_close(openedReader)
        sqlite3_close(openedWriter)
    }
    #expect(sqlite3_exec(openedWriter, "CREATE TABLE value (id INTEGER)", nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_busy_timeout(openedReader, 1) == SQLITE_OK)
    sqlite3_extended_result_codes(openedReader, 1)
    let statement = try SQLiteStatement(connection: openedReader, sql: "SELECT id FROM value")
    defer { _ = statement.finalize() }
    #expect(sqlite3_exec(openedWriter, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)

    do {
        _ = try statement.step()
        Issue.record("Expected the locked read to report SQLITE_BUSY.")
    } catch let error as SQLiteStorageError {
        guard case .queryFailed(let detail) = error,
              detail.contains("busy"),
              detail.contains("code 5") else {
            Issue.record("Expected a checked SQLITE_BUSY error, got \(error).")
            return
        }
    }
}

@Test
func statementCleanupDoesNotReplaceTheOperationError() throws {
    enum ExpectedError: Error {
        case operationFailed
    }

    let fixture = try MessageDatabaseFixture()
    let database = try SQLiteDatabase(path: fixture.path)
    #expect(throws: ExpectedError.self) {
        try database.withStatement("SELECT guid FROM message") { statement in
            _ = try statement.step()
            throw ExpectedError.operationFailed
        }
    }
    #expect(try database.firstText("SELECT guid FROM message ORDER BY ROWID LIMIT 1")
        == MessageDatabaseFixture.rootMessageID)
    #expect(throws: SQLiteStorageError.self) {
        try database.execute("SELECT 1")
    }
}

@Test
func readTransactionKeepsMultipleStatementsOnOneSnapshot() throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("PRAGMA journal_mode=WAL")
    try fixture.execute("UPDATE message SET text = text WHERE ROWID = 100")
    let database = try SQLiteDatabase(path: fixture.path)

    let values = try database.withReadTransaction {
        let before = try database.firstText("SELECT text FROM message WHERE ROWID = 100")
        try fixture.execute("UPDATE message SET text = 'Changed during read' WHERE ROWID = 100")
        let during = try database.firstText("SELECT text FROM message WHERE ROWID = 100")
        return (before, during)
    }

    #expect(values.0 == "Root message")
    #expect(values.1 == "Root message")
    #expect(try database.firstText("SELECT text FROM message WHERE ROWID = 100") == "Changed during read")
}

@Test
func cachedStorageRecoversAfterAPathDisappearsAndIsReplaced() async throws {
    let fixture = try MessageDatabaseFixture()
    let replacement = try MessageDatabaseFixture(options: .init(
        includeOptionalMessageColumns: false,
        includeOptionalChatColumns: false,
        includeOptionalAttachmentColumns: false
    ))
    try replacement.execute("UPDATE message SET text = 'Replacement message' WHERE ROWID = 100")
    let storage = fixture.makeStorage()

    let firstPage = try await storage.conversations.listConversations(
        options: ConversationListOptions(limit: 1)
    )
    let oldCursor = try #require(firstPage.nextCursor)

    try FileManager.default.removeItem(atPath: fixture.path)
    let unavailable = await storage.databaseStatus()
    #expect(!unavailable.ready)

    try FileManager.default.moveItem(atPath: replacement.path, toPath: fixture.path)
    await #expect(throws: SQLiteStorageError.invalidCursor) {
        try await storage.conversations.listConversations(
            options: ConversationListOptions(limit: 1, cursor: oldCursor)
        )
    }
    let message = try #require(try await storage.messages.message(
        id: MessageID(validating: MessageDatabaseFixture.rootMessageID)
    ))
    #expect(message.text == "Replacement message")
    try await storage.shutdown()
}

@Test
func executorRetriesOnceWhenDatabaseChangesAfterAnOperation() async throws {
    let fixture = try MessageDatabaseFixture()
    let replacement = try MessageDatabaseFixture()
    try replacement.execute("UPDATE message SET text = 'Replacement message' WHERE ROWID = 100")
    let switcher = DatabaseSwitcher(
        destinationPath: fixture.path,
        replacementPath: replacement.path
    )
    let executor = SQLiteExecutor(path: fixture.path)

    let text = try await executor.run { database in
        let value = try database.firstText("SELECT text FROM message WHERE ROWID = 100")
        try switcher.replaceOnce()
        return value
    }

    #expect(text == "Replacement message")
    #expect(switcher.attemptCount == 2)
    try await executor.shutdown()
}

private final class DatabaseSwitcher: @unchecked Sendable {
    private let lock = NSLock()
    private let destinationPath: String
    private let replacementPath: String
    private var replaced = false
    private var attempts = 0

    init(destinationPath: String, replacementPath: String) {
        self.destinationPath = destinationPath
        self.replacementPath = replacementPath
    }

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func replaceOnce() throws {
        try lock.withLock {
            attempts += 1
            guard !replaced else { return }
            replaced = true
            try FileManager.default.removeItem(atPath: destinationPath)
            try FileManager.default.moveItem(atPath: replacementPath, toPath: destinationPath)
        }
    }
}
