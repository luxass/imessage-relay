import Foundation
import Testing

@testable import RelayCore

@Test
func messageCountsUseDirectionDatesAndLogicalMessageRules() async throws {
    let fixture = try MessageDatabaseFixture(seedData: false)
    try fixture.execute("""
        ALTER TABLE message ADD COLUMN date_retracted INTEGER;
        ALTER TABLE chat_message_join RENAME TO original_joins;
        CREATE TABLE chat_message_join AS SELECT * FROM original_joins;
        DROP TABLE original_joins;
        INSERT INTO chat (ROWID, guid) VALUES (1, 'count-chat'), (2, 'other-chat'), (3, 'empty-chat');
        INSERT INTO message (ROWID, guid, text, is_from_me, date, associated_message_type,
                             balloon_bundle_id, date_retracted, schedule_type, schedule_state)
        VALUES
            (1, 'at-start', 'Received', 0, 700000000, 0, NULL, 0, 0, 0),
            (2, 'outgoing', 'Outgoing', 1, 700000020000000000, 0, NULL, 0, 0, 0),
            (3, 'at-end', 'Excluded', 0, 700000060000000000, 0, NULL, 0, 0, 0),
            (4, 'reaction', 'Excluded', 0, 700000010000000000, 2001, NULL, 0, 0, 0),
            (5, 'url-root', 'See https://example.com', 1, 700000030000000000, 0, NULL, 0, 0, 0),
            (6, 'url-preview', 'https://example.com', 1, 700000031000000000, 0, 'com.apple.messages.URLBalloonProvider', 0, 0, 0),
            (7, 'attachment-only', NULL, 0, 700000040000000000, 0, NULL, 0, 0, 0),
            (8, 'unsent', 'Former text', 0, 700000050000000000, 0, NULL, 700000055000000000, 0, 0),
            (9, 'pending', 'Not sent', 1, 700000055000000000, 0, NULL, 0, 2, 1),
            (10, 'other-associated', 'Ordinary boundary', 0, 700000045000000000, 2500, NULL, 0, 0, 0),
            (11, 'other-chat-only', 'Elsewhere', 1, 700000025000000000, 0, NULL, 0, 0, 0),
            (12, 'unknown-date', 'Unknown', 0, NULL, 0, NULL, 0, 0, 0),
            (13, 'before-start', 'Excluded', 0, 699999999000000000, 0, NULL, 0, 0, 0),
            (14, 'filtered', 'Hidden', 1, 700000035000000000, 0, NULL, 0, 0, 0);
        INSERT INTO chat_message_join (chat_id, message_id, filter_action)
        SELECT 1, ROWID, CASE WHEN ROWID = 14 THEN 1 ELSE 0 END FROM message WHERE ROWID != 11;
        INSERT INTO chat_message_join (chat_id, message_id, filter_action) VALUES (1, 5, 0), (2, 5, 0), (2, 11, 0);
        """)
    let storage = fixture.makeStorage()
    let range = try MessageCountRange(
        from: Timestamp(Date(timeIntervalSinceReferenceDate: 700_000_000)),
        to: Timestamp(Date(timeIntervalSinceReferenceDate: 700_000_060))
    )
    let counts = try await storage.messages.countMessages(conversationID: ConversationID(validating: "count-chat"), range: range)
    #expect(counts.sent == 2)
    #expect(counts.received == 4)
    let other = try await storage.messages.countMessages(conversationID: ConversationID(validating: "other-chat"), range: range)
    #expect(other.sent == 2)
    #expect(other.received == 0)
    let empty = try await storage.messages.countMessages(conversationID: ConversationID(validating: "empty-chat"), range: range)
    #expect(empty.sent == 0 && empty.received == 0)
    await #expect(throws: RelayServiceError.unknownConversation) {
        try await storage.messages.countMessages(conversationID: ConversationID(validating: "missing"), range: range)
    }
    try await storage.shutdown()
}

@Test
func messageCountsResolvePreviewParentsOutsideTheRequestedRange() async throws {
    let fixture = try MessageDatabaseFixture(seedData: false)
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid) VALUES (1, 'count-chat');
        INSERT INTO message (ROWID, guid, text, is_from_me, date, balloon_bundle_id)
        VALUES (1, 'old-root', 'https://example.com', 1, 699999999000000000, NULL),
               (2, 'preview-in-range', 'https://example.com', 1, 700000001000000000, 'com.apple.messages.URLBalloonProvider'),
               (3, 'ordinary-in-range', 'Ordinary', 1, 700000002000000000, NULL),
               (4, 'root-in-range', 'https://example.org', 1, 700000059000000000, NULL),
               (5, 'preview-after-range', 'https://example.org', 1, 700000061000000000, 'com.apple.messages.URLBalloonProvider');
        INSERT INTO chat_message_join (chat_id, message_id, filter_action) SELECT 1, ROWID, 0 FROM message;
        """)
    let storage = fixture.makeStorage()
    let counts = try await storage.messages.countMessages(
        conversationID: ConversationID(validating: "count-chat"),
        range: MessageCountRange(from: Timestamp(Date(timeIntervalSinceReferenceDate: 700_000_000)),
                                 to: Timestamp(Date(timeIntervalSinceReferenceDate: 700_000_060)))
    )
    #expect(counts.sent == 2)
    #expect(counts.received == 0)
    try await storage.shutdown()
}

@Test
func messageCountsStreamLongPreviewRunsWithoutCountingSuppressedRows() async throws {
    let fixture = try MessageDatabaseFixture()
    try insertPreviewSearchHistory(into: fixture, count: 900)
    try fixture.execute("""
        UPDATE message SET text = 'Needle https://example.com'
        WHERE guid IN ('preview-search-100', 'preview-search-600');
        """)
    let storage = fixture.makeStorage()
    let counts = try await storage.messages.countMessages(
        conversationID: ConversationID(validating: MessageDatabaseFixture.oneToOneID),
        range: MessageCountRange(from: Timestamp(Date(timeIntervalSinceReferenceDate: 799_000_000)),
                                 to: Timestamp(Date(timeIntervalSinceReferenceDate: 801_000_000)))
    )
    #expect(counts.sent == 0)
    #expect(counts.received == 101)
    try await storage.shutdown()
}

@Test
func messageCountRangesRequireAnIncreasingInterval() {
    let date = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
    #expect(throws: RelayServiceError.self) { try MessageCountRange(from: date, to: date) }
    #expect(throws: RelayServiceError.self) {
        try MessageCountRange(from: date, to: Timestamp(date.date.addingTimeInterval(-1)))
    }
}
