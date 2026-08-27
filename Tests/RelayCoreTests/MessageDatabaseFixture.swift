import Foundation
import SQLite3

@testable import RelayCore

final class MessageDatabaseFixture {
    struct SchemaOptions {
        var includeReadState = true
        var includeReactions = true
        var includeReplies = true
        var includeReceipts = true
        var includeAttachmentMetadata = true
    }

    enum FixtureError: Error {
        case cannotOpen(String)
        case cannotExecute(String)
    }

    let path: String

    private let directory: URL
    private var database: OpaquePointer?

    init(
        options: SchemaOptions = SchemaOptions(),
        seedData: Bool = true,
        unreadInChat1: Bool = false
    ) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("chat.db").path

        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw FixtureError.cannotOpen(detail)
        }
        database = handle

        try createSchema(options: options)
        if seedData {
            try seed(unreadInChat1: unreadInChat1)
        }
    }

    deinit {
        sqlite3_close(database)
        try? FileManager.default.removeItem(at: directory)
    }

    func makeStore() throws -> MessageStore {
        try MessageStore(path: path)
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw FixtureError.cannotExecute(detail)
        }
    }

    private func createSchema(options: SchemaOptions) throws {
        let readState = options.includeReadState ? ", is_read INTEGER DEFAULT 1" : ""
        let reactions = options.includeReactions
            ? ", associated_message_type INTEGER DEFAULT 0, associated_message_guid TEXT"
            : ""
        let replies = options.includeReplies ? ", thread_originator_guid TEXT" : ""
        let receipts = options.includeReceipts ? ", date_delivered REAL, date_read REAL" : ""
        let attachmentMetadata = options.includeAttachmentMetadata
            ? ", transfer_name TEXT, mime_type TEXT, uti TEXT, total_bytes INTEGER DEFAULT 0, is_sticker INTEGER DEFAULT 0"
            : ""
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
                date REAL
                \(readState)
                \(reactions)
                \(replies)
                \(receipts)
            );
            CREATE TABLE chat_message_join (
                chat_id INTEGER,
                message_id INTEGER,
                PRIMARY KEY (chat_id, message_id)
            );
            CREATE TABLE chat_handle_join (
                chat_id INTEGER,
                handle_id INTEGER,
                PRIMARY KEY (chat_id, handle_id)
            );
            CREATE TABLE attachment (
                ROWID INTEGER PRIMARY KEY,
                filename TEXT
                \(attachmentMetadata)
            );
            CREATE TABLE message_attachment_join (
                message_id INTEGER,
                attachment_id INTEGER,
                PRIMARY KEY (message_id, attachment_id)
            );
            """)
    }

    private func seed(unreadInChat1: Bool) throws {
        try execute("""
            INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
            VALUES (1, 'iMessage;-;+15551230001', '+15551230001', 'iMessage');

            INSERT INTO handle (ROWID, id) VALUES (10, '+15551230001');
            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 10);

            INSERT INTO message
                (ROWID, guid, text, handle_id, is_from_me, is_read, date)
            VALUES
                (100, 'guid-100', 'hello', 10, 0, \(unreadInChat1 ? 0 : 1), 700000000);

            INSERT INTO message
                (ROWID, guid, text, handle_id, is_from_me, is_read,
                 date, date_delivered, date_read)
            VALUES
                (101, 'guid-101', 'hi there', NULL, 1, 1,
                 700000060, 700000065, 700000070);

            INSERT INTO message
                (ROWID, guid, text, handle_id, is_from_me, is_read, date,
                 associated_message_type, associated_message_guid)
            VALUES
                (102, 'guid-102', 'loved an image', 10, 0, 1,
                 700000120, 2000, 'guid-101');

            INSERT INTO chat_message_join (chat_id, message_id)
            VALUES (1, 100), (1, 101), (1, 102);
            """)
    }
}
