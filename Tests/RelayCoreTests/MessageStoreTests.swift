import XCTest
import Foundation
import SQLite3
@testable import RelayCore

final class MessageStoreTests: XCTestCase {

    /// Builds a hermetic fixture database with the minimal chat.db schema
    /// subset the store queries. No Full Disk Access or real Messages data.
    private func makeFixtureDB(unreadInChat1: Bool = false) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("chat.db").path

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let opened = db else {
            XCTFail("could not create fixture database")
            return path
        }
        defer { sqlite3_close(opened) }

        let ddl = """
        CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, service_name TEXT, display_name TEXT);
        CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
        CREATE TABLE message (
            ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, handle_id INTEGER,
            is_from_me INTEGER DEFAULT 0, is_read INTEGER DEFAULT 1,
            date REAL, associated_message_type INTEGER DEFAULT 0,
            associated_message_guid TEXT, thread_originator_guid TEXT,
            date_delivered REAL, date_read REAL
        );
        CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, PRIMARY KEY (chat_id, message_id));
        CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER, PRIMARY KEY (chat_id, handle_id));
        CREATE TABLE attachment (
            ROWID INTEGER PRIMARY KEY, filename TEXT, transfer_name TEXT, mime_type TEXT,
            uti TEXT, total_bytes INTEGER DEFAULT 0, is_sticker INTEGER DEFAULT 0
        );
        CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER, PRIMARY KEY (message_id, attachment_id));

        INSERT INTO chat (ROWID, guid, chat_identifier, service_name) VALUES (1, 'iMessage;-;+15551230001', '+15551230001', 'iMessage');
        INSERT INTO handle (ROWID, id) VALUES (10, '+15551230001');
        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (1, 10);

        -- Apple reference-date epoch: 700000000 ≈ 2023-02-15.
        -- Row 101 is outgoing and carries delivery/read receipts; incoming
        -- rows never do.
        INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, is_read, date) VALUES
            (100, 'guid-100', 'hello', 10, 0, \(unreadInChat1 ? "0" : "1"), 700000000);
        INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, is_read,
                             date, date_delivered, date_read) VALUES
            (101, 'guid-101', 'hi there', NULL, 1, 1, 700000060, 700000065, 700000070);
        INSERT INTO message (ROWID, guid, text, handle_id, is_from_me, is_read, date,
                             associated_message_type, associated_message_guid) VALUES
            (102, 'guid-102', 'loved an image', 10, 0, 1, 700000120, 2000, 'guid-101');

        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 100), (1, 101), (1, 102);
        """
        var execError: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(opened, ddl, nil, nil, &execError) == SQLITE_OK else {
            let detail = execError.map { String(cString: $0) } ?? "unknown"
            XCTFail("fixture DDL failed: \(detail)")
            return path
        }
        return path
    }

    func testChatsListsChatsWithParticipants() throws {
        let store = try MessageStore(path: makeFixtureDB())
        let chats = try store.chats()
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].id, 1)
        XCTAssertEqual(chats[0].identifier, "+15551230001")
        XCTAssertEqual(chats[0].participants, ["+15551230001"])
        XCTAssertFalse(chats[0].isGroup)
        XCTAssertNil(chats[0].displayName)
        XCTAssertEqual(chats[0].name, chats[0].identifier)
    }

    func testUnreadOnlyFilter() throws {
        let unread = try MessageStore(path: makeFixtureDB(unreadInChat1: true))
        XCTAssertEqual(try unread.chats(unreadOnly: true).count, 1)
        XCTAssertEqual(try unread.chats().count, 1)

        let read = try MessageStore(path: makeFixtureDB())
        XCTAssertEqual(try read.chats(unreadOnly: true).count, 0)
        XCTAssertEqual(try read.chats().count, 1)
    }

    func testMessagesHidesTapbacksAndReturnsChronological() throws {
        let store = try MessageStore(path: makeFixtureDB())
        let messages = try store.messages(chatID: 1)
        XCTAssertEqual(messages.map(\.id), [100, 101]) // tapback row 102 hidden
        XCTAssertEqual(messages[0].text, "hello")
        XCTAssertFalse(messages[0].isFromMe)
        XCTAssertTrue(messages[1].isFromMe)
    }

    func testMessagesIncludeReactionsParity() throws {
        let store = try MessageStore(path: makeFixtureDB())
        let withReactions = try store.messages(chatID: 1, includeReactions: true)
        XCTAssertEqual(withReactions.map(\.id), [100, 101, 102])
        XCTAssertTrue(withReactions[2].isReaction == true)
        XCTAssertEqual(withReactions[2].reactedToGuid, "guid-101")
        XCTAssertEqual(withReactions[2].reactionType, "love")
        XCTAssertEqual(withReactions[2].isReactionAdd, true)

        // Default stays tapback-free.
        XCTAssertEqual(try store.messages(chatID: 1).map(\.id), [100, 101])
    }

    func testReceiptsSurfaceOnOutgoingMessagesOnly() throws {
        let store = try MessageStore(path: makeFixtureDB())

        // History and catch-up both carry rows 100 (incoming) and 101 (outgoing).
        for messages in [
            try store.messages(chatID: 1),
            try store.messagesAfter(sinceRowid: 99).messages,
        ] {
            let incoming = try XCTUnwrap(messages.first { $0.id == 100 })
            let outgoing = try XCTUnwrap(messages.first { $0.id == 101 })
            XCTAssertNil(incoming.deliveredAt)
            XCTAssertNil(incoming.readAt)
            XCTAssertNotNil(outgoing.deliveredAt)
            XCTAssertNotNil(outgoing.readAt)
        }

        // Search surfaces the same fields on whatever it matches.
        let outgoingHit = try XCTUnwrap(try store.search(query: "hi there").first)
        XCTAssertEqual(outgoingHit.id, 101)
        XCTAssertNotNil(outgoingHit.deliveredAt)
        XCTAssertNotNil(outgoingHit.readAt)

        let incomingHit = try XCTUnwrap(try store.search(query: "hello").first)
        XCTAssertEqual(incomingHit.id, 100)
        XCTAssertNil(incomingHit.deliveredAt)
    }

    func testMessagesAfterCursorSkipsReactionsAndAdvancesPastThem() throws {
        let store = try MessageStore(path: makeFixtureDB())

        // Default: reaction row suppressed, cursor still advances past it.
        let page = try store.messagesAfter(sinceRowid: 99, chatID: nil)
        XCTAssertEqual(page.messages.map(\.id), [100, 101])
        XCTAssertEqual(page.nextRowid, 102) // physical scan reached the tapback row
        XCTAssertFalse(page.hasMore)

        // With reactions included the same scan emits the tapback explicitly.
        let withReactions = try store.messagesAfter(sinceRowid: 99, includeReactions: true)
        XCTAssertEqual(withReactions.messages.map(\.id), [100, 101, 102])
        XCTAssertTrue(withReactions.messages[2].isReaction == true)
        XCTAssertEqual(withReactions.messages[2].reactedToGuid, "guid-101")
        XCTAssertEqual(withReactions.messages[2].reactionType, "love")
        XCTAssertEqual(withReactions.messages[2].isReactionAdd, true)
    }

    func testSearchFindsSubstring() throws {
        let store = try MessageStore(path: makeFixtureDB())
        let hits = try store.search(query: "hello")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].guid, "guid-100")

        let none = try store.search(query: "%")
        XCTAssertEqual(none.count, 0, "percent must be escaped, not treated as wildcard")
    }

    func testStatusReportsReadyAndFingerprint() throws {
        let store = try MessageStore(path: makeFixtureDB())
        let status = store.status()
        XCTAssertTrue(status.ready)
        XCTAssertNil(status.error)
        XCTAssertTrue(status.fingerprint.contains("pages="))
    }
}
