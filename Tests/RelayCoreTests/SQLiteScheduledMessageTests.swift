import Foundation
import Testing

@testable import RelayCore

@Test
func scheduledQueueFiltersProviderStatesAndPaginatesAcrossConversations() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("ALTER TABLE message ADD COLUMN date_retracted INTEGER;")
    try fixture.execute("ALTER TABLE message ADD COLUMN date_edited INTEGER;")
    let base = Int64(Date().timeIntervalSinceReferenceDate) + 600
    for index in 1...17 {
        let date = index == 3 ? base - 1200 : (index == 15 ? base + 600 : base)
        let rawDate = index == 1 ? date : date * 1_000_000_000
        let type = index == 5 || index == 17 ? 0 : (index == 7 ? 8 : 2)
        let state = index == 5 || index == 16 ? 0 : (index == 6 ? 3 : (index == 7 ? 99 : 1))
        try fixture.execute("""
            INSERT INTO message (ROWID, guid, text, is_from_me, date, schedule_type, schedule_state,
                                 is_sent, is_delivered, date_delivered, date_retracted, error, associated_message_type)
            VALUES (\(600 + index), 'scheduled-\(index)', 'Scheduled fixture', \(index == 4 ? 0 : 1),
                    \(rawDate), \(type), \(state), \(index == 8 ? 1 : 0), \(index == 9 ? 1 : 0),
                    \(index == 10 ? 1 : 0), \(index == 11 ? 1 : 0), \(index == 12 ? 1 : 0), \(index == 13 ? 2001 : 0));
            INSERT INTO chat_message_join (chat_id, message_id, filter_action)
            VALUES (\(index == 15 ? 2 : 1), \(600 + index), \(index == 14 ? 1 : 0));
            """)
    }
    try fixture.execute("""
        INSERT INTO chat_message_join (chat_id, message_id, filter_action) VALUES (2, 601, 0);
        UPDATE message SET text = 'stale', date_edited = 100 WHERE ROWID = 615;
        """)
    try fixture.setAttributedBody(
        messageRowID: 615, data: MessageDatabaseFixture.archivedAttributedString(NSAttributedString(string: "Current scheduled text"))
    )
    let storage = fixture.makeStorage()
    var cursor: Cursor?
    var results: [Message] = []
    for _ in 0..<5 {
        let page = try await storage.messages.listScheduledMessages(options: ScheduledMessageListOptions(limit: 1, cursor: cursor))
        results += page.items
        if !page.hasMore { break }
        let next = try #require(page.nextCursor)
        #expect(next != cursor)
        cursor = next
    }
    #expect(results.map(\.id.rawValue) == ["scheduled-1", "scheduled-2", "scheduled-15"])
    #expect(results.last?.text == "Current scheduled text")
    #expect(results.last?.conversationID.rawValue == MessageDatabaseFixture.groupID)
    #expect(results.allSatisfy { $0.schedule?.type == 2 && $0.schedule?.state == 1 && $0.schedule?.scheduledAt != nil })
    try await storage.shutdown()
}

@Test
func scheduledQueueRejectsUnsupportedSchemasAndIncompatibleCursors() async throws {
    let fixture = try MessageDatabaseFixture(options: .init(includeOptionalMessageColumns: false))
    let storage = fixture.makeStorage()
    await #expect(throws: RelayServiceError.unsupportedCapability("Scheduled messages require schedule and sent-state columns.")) {
        try await storage.messages.listScheduledMessages(options: ScheduledMessageListOptions())
    }
    try await storage.shutdown()
    let supported = try MessageDatabaseFixture()
    let regular = supported.makeStorage()
    let history = try await regular.messages.listMessages(
        conversationID: nil, options: MessageListOptions(limit: 1)
    )
    let cursor = try #require(history.nextCursor)
    await #expect(throws: SQLiteStorageError.invalidCursor) {
        try await regular.messages.listScheduledMessages(options: ScheduledMessageListOptions(cursor: cursor))
    }
    try await regular.shutdown()
}
