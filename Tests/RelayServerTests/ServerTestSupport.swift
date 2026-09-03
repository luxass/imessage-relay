import Foundation
import Hummingbird
import Logging
import RelayCore
import SQLite3

@testable import relay_server

final class ServerDatabaseFixture: @unchecked Sendable {
    enum FixtureError: Error {
        case cannotOpen(String)
        case cannotExecute(String)
    }

    let path: String
    let attachmentData: Data

    private let directory: URL
    private var database: OpaquePointer?

    init(
        attachmentData: Data = Data("fixture attachment".utf8),
        attachmentMimeType: String? = "text/plain"
    ) throws {
        self.attachmentData = attachmentData
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-server-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("chat.db").path

        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw FixtureError.cannotOpen(detail)
        }
        database = handle

        let attachmentDirectory = directory.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(
            at: attachmentDirectory,
            withIntermediateDirectories: true
        )
        let attachmentPath = attachmentDirectory.appendingPathComponent("fixture.txt")
        try attachmentData.write(to: attachmentPath)
        try execute("""
            CREATE TABLE chat (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                chat_identifier TEXT,
                service_name TEXT,
                display_name TEXT
            );
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                text TEXT,
                handle_id INTEGER,
                is_from_me INTEGER DEFAULT 0,
                is_read INTEGER DEFAULT 1,
                date REAL,
                associated_message_type INTEGER DEFAULT 0,
                associated_message_guid TEXT,
                thread_originator_guid TEXT,
                date_delivered REAL,
                date_read REAL
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE attachment (
                ROWID INTEGER PRIMARY KEY,
                filename TEXT,
                transfer_name TEXT,
                mime_type TEXT,
                uti TEXT,
                total_bytes INTEGER DEFAULT 0,
                is_sticker INTEGER DEFAULT 0
            );
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);

            INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
            VALUES (1, 'iMessage;-;+15551230001', '+15551230001', 'iMessage');
            INSERT INTO handle (ROWID, id) VALUES (10, '+15551230001');
            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 10);
            INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
            VALUES (2, 'iMessage;+;synthetic-group', 'synthetic-group', 'iMessage');
            INSERT INTO handle (ROWID, id) VALUES (11, 'member_one@example.com');
            INSERT INTO handle (ROWID, id) VALUES (12, 'member-two@example.com');
            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (2, 11);
            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (2, 12);
            INSERT INTO message
                (ROWID, guid, text, handle_id, is_from_me, is_read, date)
            VALUES (100, 'guid-100', 'hello fixture', 10, 0, 1, 700000000);
            INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 100);
            INSERT INTO attachment
                (ROWID, filename, transfer_name, mime_type, uti, total_bytes)
            VALUES
                (7, '\(attachmentPath.path)', 'fixture.txt', \(attachmentMimeType.map { "'\($0)'" } ?? "NULL"),
                 'public.plain-text', \(attachmentData.count));
            INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (100, 7);
            """)
    }

    deinit {
        sqlite3_close(database)
        try? FileManager.default.removeItem(at: directory)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw FixtureError.cannotExecute(detail)
        }
    }
}

final class FakeMessageSender: MessageSending, @unchecked Sendable {
    enum Outcome: Sendable {
        case success
        case unavailable(String)
        case notStarted(String)
        case uncertain(String)
    }

    let capabilities: [String]
    let isAvailable: Bool

    private let lock = NSLock()
    private let outcome: Outcome
    private var recordedRequests: [SendRequest] = []

    init(
        capabilities: [String] = ["text"],
        isAvailable: Bool = true,
        outcome: Outcome = .success
    ) {
        self.capabilities = capabilities
        self.isAvailable = isAvailable
        self.outcome = outcome
    }

    var requests: [SendRequest] {
        lock.withLock { recordedRequests }
    }

    func send(_ request: SendRequest) async throws -> SendResult {
        lock.withLock { recordedRequests.append(request) }
        switch outcome {
        case .success:
            return SendResult(ok: true, guid: "fake-guid")
        case .unavailable(let detail):
            throw SenderError.unavailable(detail)
        case .notStarted(let detail):
            throw SenderError.notStarted(detail: detail)
        case .uncertain(let detail):
            throw SenderError.uncertain(detail: detail)
        }
    }
}

func makeTestApplication(
    databasePath: String,
    token: String? = nil,
    allowedRecipients: Set<String> = [ServerConfig.normalizeRecipient("+15551230001")],
    sender: any MessageSending = FakeMessageSender(),
    logger: Logger? = nil
) -> some ApplicationProtocol {
    let config = ServerConfig(
        allowedRecipients: allowedRecipients,
        token: token,
        databasePath: databasePath
    )
    return buildApplication(
        configuration: .init(
            address: .hostname("127.0.0.1", port: 0),
            serverName: "relay-server-tests"
        ),
        serverConfig: config,
        store: MessageStore(path: databasePath),
        sender: sender,
        logger: logger
    )
}

final class FakeSendProcessRunner: SendProcessRunning, @unchecked Sendable {
    struct Invocation: Sendable {
        let executablePath: String
        let arguments: [String]
        let standardInput: Data
        let timeout: Duration
        let terminationGrace: Duration
    }

    private let lock = NSLock()
    private let result: SendProcessResult
    private var recordedInvocations: [Invocation] = []

    init(result: SendProcessResult) {
        self.result = result
    }

    var invocations: [Invocation] {
        lock.withLock { recordedInvocations }
    }

    func run(
        executablePath: String,
        arguments: [String],
        standardInput: Data,
        timeout: Duration,
        terminationGrace: Duration
    ) async -> SendProcessResult {
        lock.withLock {
            recordedInvocations.append(.init(
                executablePath: executablePath,
                arguments: arguments,
                standardInput: standardInput,
                timeout: timeout,
                terminationGrace: terminationGrace
            ))
        }
        return result
    }
}

final class CapturedLogs: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [String] = []

    var entries: [String] {
        lock.withLock { storedEntries }
    }

    func append(message: Logger.Message, metadata: Logger.Metadata?) {
        lock.withLock {
            storedEntries.append("\(message) \(metadata ?? [:])")
        }
    }
}

struct CapturingLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    let capturedLogs: CapturedLogs

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        capturedLogs.append(
            message: event.message,
            metadata: metadata.merging(event.metadata ?? [:]) { _, new in new }
        )
    }
}
