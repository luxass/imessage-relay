import Testing

@testable import RelayCore

@Test
func globalSearchUsesCanonicalVisibleConversationsAndStableOrdering() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        ALTER TABLE chat_message_join RENAME TO original_joins;
        CREATE TABLE chat_message_join AS SELECT * FROM original_joins;
        DROP TABLE original_joins;
        UPDATE message SET text = 'CAFÉ', date = 700000000000000000 WHERE ROWID IN (100, 101);
        INSERT INTO chat_message_join (chat_id, message_id, filter_action) VALUES (1, 100, 0), (2, 100, 0);
        INSERT INTO message (ROWID, guid, text, is_from_me, date) VALUES (600, 'null-date-match', 'cafe', 0, NULL);
        INSERT INTO chat_message_join (chat_id, message_id, filter_action) VALUES (2, 600, 0);
        """)
    let storage = fixture.makeStorage()
    var cursor: Cursor?
    var results: [Message] = []
    for _ in 0..<5 {
        let page = try await storage.messages.listMessages(
            conversationID: nil, options: MessageListOptions(limit: 1, cursor: cursor, search: "cafe", searchMode: .exact)
        )
        results += page.items
        if !page.hasMore { break }
        cursor = try #require(page.nextCursor)
    }
    #expect(results.map(\.id.rawValue) == [
        "00000000-0000-0000-0000-000000000101", MessageDatabaseFixture.rootMessageID, "null-date-match",
    ])
    #expect(results[1].conversationID.rawValue == MessageDatabaseFixture.oneToOneID)
    #expect(results.last?.conversationID.rawValue == MessageDatabaseFixture.groupID)
    try fixture.execute("UPDATE chat_message_join SET filter_action = 1 WHERE chat_id = 1 AND message_id = 100;")
    let visible = try await storage.messages.listMessages(
        conversationID: nil, options: MessageListOptions(search: "cafe", searchMode: .exact)
    )
    #expect(visible.items.first { $0.id.rawValue == MessageDatabaseFixture.rootMessageID }?.conversationID.rawValue
        == MessageDatabaseFixture.groupID)
    try await storage.shutdown()
}

@Test
func globalSearchCursorsRejectOtherQueriesScopesAndDatabases() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("UPDATE message SET text = 'fixture match' WHERE ROWID IN (100, 101);")
    let storage = fixture.makeStorage()
    let page = try await storage.messages.listMessages(
        conversationID: nil, options: MessageListOptions(limit: 1, search: "fixture")
    )
    let cursor = try #require(page.nextCursor)
    for options in [
        MessageListOptions(cursor: cursor, search: "different"),
        MessageListOptions(cursor: cursor, search: "fixture", searchMode: .exact),
        MessageListOptions(cursor: cursor, includeAttachments: true, search: "fixture"),
    ] {
        await #expect(throws: SQLiteStorageError.invalidCursor) {
            try await storage.messages.listMessages(conversationID: nil, options: options)
        }
    }
    await #expect(throws: SQLiteStorageError.invalidCursor) {
        try await storage.messages.listMessages(
            conversationID: ConversationID(validating: MessageDatabaseFixture.oneToOneID),
            options: MessageListOptions(cursor: cursor, search: "fixture")
        )
    }
    let replacement = try MessageDatabaseFixture()
    let other = replacement.makeStorage()
    await #expect(throws: SQLiteStorageError.invalidCursor) {
        try await other.messages.listMessages(
            conversationID: nil, options: MessageListOptions(cursor: cursor, search: "fixture")
        )
    }
    try await storage.shutdown()
    try await other.shutdown()
}

@Test
func globalSearchRetainsBoundedPreviewContinuationAndSparseMatches() async throws {
    let fixture = try MessageDatabaseFixture()
    try insertPreviewSearchHistory(into: fixture, count: 900)
    try fixture.execute("""
        UPDATE message SET text = 'Needle https://example.com'
        WHERE guid IN ('preview-search-100', 'preview-search-600');
        INSERT INTO chat_message_join (chat_id, message_id, filter_action)
        SELECT 2, ROWID, 0 FROM message WHERE ROWID >= 1000;
        """)
    let storage = fixture.makeStorage()
    let small = try await collectPreviewSearch(storage, limit: 32, search: "needle", global: true)
    let large = try await collectPreviewSearch(storage, limit: 200, search: "needle", global: true)
    #expect(small.map(\.id) == large.map(\.id))
    #expect(small.map(\.urlPreview) == large.map(\.urlPreview))
    #expect(small.map(\.id.rawValue) == (0...100).reversed().map { "preview-search-\($0)" })
    #expect(small.first?.urlPreview?.messageID.rawValue == "preview-search-899")
    let sparse = try await collectPreviewSearch(storage, limit: 1, search: "never present", global: true)
    #expect(sparse.isEmpty)
    try await storage.shutdown()
}

@Test
func globalSearchNeverCoalescesPreviewMessagesAcrossConversations() async throws {
    let fixture = try MessageDatabaseFixture(seedData: false)
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid) VALUES (1, 'chat-a'), (2, 'chat-b');
        INSERT INTO message (ROWID, guid, text, is_from_me, date, balloon_bundle_id)
        VALUES (1, 'root-a', 'https://example.com', 0, 700000000000000000, NULL),
               (2, 'preview-b', 'https://example.com', 0, 700000001000000000, 'com.apple.messages.URLBalloonProvider');
        INSERT INTO chat_message_join (chat_id, message_id, filter_action) VALUES (1, 1, 0), (2, 2, 0);
        """)
    let storage = fixture.makeStorage()
    let page = try await storage.messages.listMessages(
        conversationID: nil, options: MessageListOptions(search: "example.com")
    )
    #expect(page.items.map(\.id.rawValue) == ["preview-b", "root-a"])
    #expect(page.items.allSatisfy { $0.urlPreview == nil })
    try await storage.shutdown()
}
