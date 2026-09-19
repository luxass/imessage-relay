import Foundation
import SQLite3

@testable import RelayCore

final class MessageDatabaseFixture: @unchecked Sendable {
    struct SchemaOptions {
        var includeOptionalMessageColumns = true
        var includeOptionalChatColumns = true
        var includeOptionalAttachmentColumns = true
    }

    enum FixtureError: Error {
        case cannotOpen(String)
        case cannotExecute(String)
    }

    static let oneToOneID = "iMessage;-;+15005550006"
    static let groupID = "iMessage;+;group-fixture-guid"
    static let rootMessageID = "00000000-0000-0000-0000-000000000100"
    static let immediateReplyID = "00000000-0000-0000-0000-000000000103"
    static let nestedReplyID = "00000000-0000-0000-0000-000000000104"
    static let attachmentID = "00000000-0000-0000-0000-000000000201"

    let path: String
    let attachmentDirectory: URL

    private let directory: URL
    private var database: OpaquePointer?

    init(options: SchemaOptions = SchemaOptions(), seedData: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-tests-\(UUID().uuidString)", isDirectory: true)
        attachmentDirectory = directory.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("chat.db", isDirectory: false).path

        var opened: OpaquePointer?
        guard sqlite3_open(path, &opened) == SQLITE_OK, let opened else {
            let detail = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(opened)
            throw FixtureError.cannotOpen(detail)
        }
        database = opened
        do {
            try createSchema(options: options)
            if seedData { try seed(options: options) }
        } catch {
            sqlite3_close(database)
            database = nil
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
        try? FileManager.default.removeItem(at: directory)
    }

    func makeStorage() -> MessagesStorage {
        MessagesStorage(path: path, attachmentDirectory: attachmentDirectory.path)
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
        let chatOptional = options.includeOptionalChatColumns
            ? ", display_name TEXT, room_name TEXT, account_id TEXT, account_login TEXT"
            : ""
        let messageOptional = options.includeOptionalMessageColumns
            ? """
              , attributedBody BLOB, error INTEGER, is_sent INTEGER, is_delivered INTEGER,
                is_read INTEGER, date_delivered INTEGER, date_read INTEGER,
                reply_to_guid TEXT, thread_originator_guid TEXT,
                part_count INTEGER,
                associated_message_guid TEXT, associated_message_type INTEGER,
                associated_message_emoji TEXT, item_type INTEGER,
                is_finished INTEGER, is_system_message INTEGER
              """
            : ""
        let attachmentOptional = options.includeOptionalAttachmentColumns
            ? ", transfer_name TEXT, mime_type TEXT, uti TEXT, total_bytes INTEGER"
            : ""
        try execute("""
            CREATE TABLE chat (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT UNIQUE NOT NULL,
                chat_identifier TEXT,
                service_name TEXT
                \(chatOptional)
            );
            CREATE TABLE handle (
                ROWID INTEGER PRIMARY KEY,
                id TEXT NOT NULL,
                service TEXT NOT NULL,
                uncanonicalized_id TEXT,
                UNIQUE(id, service)
            );
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT UNIQUE NOT NULL,
                text TEXT,
                handle_id INTEGER,
                is_from_me INTEGER,
                date INTEGER
                \(messageOptional)
            );
            CREATE TABLE chat_message_join (
                chat_id INTEGER NOT NULL,
                message_id INTEGER NOT NULL,
                message_date INTEGER,
                filter_action INTEGER DEFAULT 0,
                PRIMARY KEY (chat_id, message_id)
            );
            CREATE TABLE chat_handle_join (
                chat_id INTEGER NOT NULL,
                handle_id INTEGER NOT NULL,
                PRIMARY KEY (chat_id, handle_id)
            );
            CREATE TABLE attachment (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT UNIQUE NOT NULL,
                original_guid TEXT UNIQUE NOT NULL,
                filename TEXT
                \(attachmentOptional)
            );
            CREATE TABLE message_attachment_join (
                message_id INTEGER NOT NULL,
                attachment_id INTEGER NOT NULL,
                PRIMARY KEY (message_id, attachment_id)
            );
            """)
    }

    private func seed(options: SchemaOptions) throws {
        guard options.includeOptionalMessageColumns,
              options.includeOptionalChatColumns,
              options.includeOptionalAttachmentColumns else {
            try seedMinimal()
            return
        }
        let attachmentURL = attachmentDirectory
            .appendingPathComponent("fixture", isDirectory: true)
            .appendingPathComponent("photo.jpg", isDirectory: false)
        try FileManager.default.createDirectory(
            at: attachmentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture attachment".utf8).write(to: attachmentURL)

        let attachmentPath = attachmentURL.path.replacingOccurrences(of: "'", with: "''")
        try execute("""
            INSERT INTO chat
                (ROWID, guid, chat_identifier, service_name, display_name, room_name, account_id, account_login)
            VALUES
                (1, '\(Self.oneToOneID)', '+15005550006', 'iMessage', NULL, NULL,
                 'account-guid-imessage', 'sender@example.com'),
                (2, '\(Self.groupID)', 'group-fixture-guid', 'iMessage', 'Fixture group',
                 'group-fixture-guid', 'account-guid-imessage', 'sender@example.com');

            INSERT INTO handle (ROWID, id, service, uncanonicalized_id) VALUES
                (10, '+15005550006', 'iMessage', '+1 500 555 0006'),
                (11, 'friend@example.com', 'iMessage', 'Friend@Example.COM');

            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES
                (1, 10), (2, 10), (2, 11);

            INSERT INTO message
                (ROWID, guid, text, handle_id, is_from_me, date, error, is_sent,
                 is_delivered, is_read, date_delivered, date_read, reply_to_guid,
                 thread_originator_guid, part_count, associated_message_guid, associated_message_type,
                 associated_message_emoji, item_type, is_finished, is_system_message)
            VALUES
                (100, '\(Self.rootMessageID)', 'Root message', 10, 0,
                 700000000000000000, 0, 0, 0, 0, 0, 0, NULL, NULL, 1, NULL, 0, NULL, 0, 1, 0),
                (101, '00000000-0000-0000-0000-000000000101', 'Outgoing message', NULL, 1,
                 700000060000000000, 0, 1, 1, 1, 700000065000000000,
                 700000070000000000, '\(Self.rootMessageID)', NULL, 1, NULL, 0, NULL, 0, 1, 0),
                (102, '00000000-0000-0000-0000-000000000102', NULL, 10, 0,
                 700000120000000000, 0, 0, 0, 1, 0, 0, NULL, NULL, 2, NULL, 0, NULL, 0, 1, 0),
                (103, '\(Self.immediateReplyID)', 'Immediate reply', 10, 0,
                 700000180000000000, 0, 0, 0, 1, 0, 0, '\(Self.rootMessageID)',
                 '\(Self.rootMessageID)', 1, NULL, 0, NULL, 0, 1, 0),
                (104, '\(Self.nestedReplyID)', 'Nested reply', NULL, 1,
                 700000240000000000, 0, 1, 0, 1, 0, 0, '\(Self.immediateReplyID)',
                 '\(Self.rootMessageID)', 1, NULL, 0, NULL, 0, 1, 0),
                (105, '00000000-0000-0000-0000-000000000105', NULL, 10, 0,
                 700000300000000000, 0, 0, 0, 1, 0, 0, NULL, NULL,
                 1, 'p:0/\(Self.rootMessageID)', 2000, NULL, 0, 1, 0),
                (106, '00000000-0000-0000-0000-000000000106', NULL, 11, 0,
                 700000360000000000, 0, 0, 0, 1, 0, 0, NULL, NULL,
                 1, 'bp:\(Self.rootMessageID)', 2006, '🎉', 0, 1, 0),
                (200, '00000000-0000-0000-0000-000000000200', 'Group message', 11, 0,
                 700000420000000000, 0, 0, 0, 1, 0, 0, NULL, NULL, 1, NULL, 0, NULL, 0, 1, 0);

            INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action) VALUES
                (1, 100, 700000000000000000, 0),
                (1, 101, 700000060000000000, 0),
                (1, 102, 700000120000000000, 0),
                (1, 103, 700000180000000000, 0),
                (1, 104, 700000240000000000, 0),
                (1, 105, 700000300000000000, 0),
                (1, 106, 700000360000000000, 0),
                (2, 200, 700000420000000000, 0);

            INSERT INTO attachment
                (ROWID, guid, original_guid, filename, transfer_name, mime_type, uti, total_bytes)
            VALUES
                (201, '\(Self.attachmentID)', 'original-attachment-guid', '\(attachmentPath)',
                 'photo.jpg', 'image/jpeg', 'public.jpeg', 18);
            INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (102, 201);
            """)
        try bindMultipartAttributedBody(messageRowID: 102)
    }

    private func bindMultipartAttributedBody(messageRowID: Int64) throws {
        let body = NSMutableAttributedString(string: "\u{fffc}Attributed fixture text")
        body.addAttribute(
            NSAttributedString.Key("__kIMMessagePartAttributeName"),
            value: 0,
            range: NSRange(location: 0, length: 1)
        )
        body.addAttribute(
            NSAttributedString.Key("__kIMFileTransferGUIDAttributeName"),
            value: Self.attachmentID,
            range: NSRange(location: 0, length: 1)
        )
        body.addAttribute(
            NSAttributedString.Key("__kIMMessagePartAttributeName"),
            value: 1,
            range: NSRange(location: 1, length: body.length - 1)
        )
        try bindAttributedBody(messageRowID: messageRowID, data: NSArchiver.archivedData(withRootObject: body))
    }

    private func seedMinimal() throws {
        try execute("""
            INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
            VALUES (1, '\(Self.oneToOneID)', '+15005550006', 'iMessage');
            INSERT INTO handle (ROWID, id, service, uncanonicalized_id)
            VALUES (10, '+15005550006', 'iMessage', '+1 500 555 0006');
            INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 10);
            INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, date)
            VALUES (100, '\(Self.rootMessageID)', NULL, 10, 0, NULL);
            INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
            VALUES (1, 100, NULL, 0);
            """)
    }

    private func bindAttributedBody(messageRowID: Int64, data: Data) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "UPDATE message SET attributedBody = ? WHERE ROWID = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw FixtureError.cannotExecute("Could not prepare attributed-body fixture update.")
        }
        defer { sqlite3_finalize(statement) }
        data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        sqlite3_bind_int64(statement, 2, messageRowID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw FixtureError.cannotExecute("Could not save attributed-body fixture.")
        }
    }
}
