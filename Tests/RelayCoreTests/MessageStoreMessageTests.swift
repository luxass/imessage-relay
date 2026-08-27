import Testing

@testable import RelayCore

@Test
func historyHidesReactionsAndReturnsChronologicalRows() async throws {
    let fixture = try MessageDatabaseFixture()
    let messages = try await fixture.makeStore().messages(chatID: 1)

    #expect(messages.items.map(\.id) == [100, 101])
    #expect(messages.items[0].text == "hello")
    #expect(messages.items[0].createdAt == "2023-03-08T20:26:40Z")
    #expect(!messages.items[0].isFromMe)
    #expect(messages.items[1].isFromMe)
}

@Test
func historyCanIncludeReactionEvents() async throws {
    let fixture = try MessageDatabaseFixture()
    let store = fixture.makeStore()
    let messages = try await store.messages(chatID: 1, includeReactions: true)

    #expect(messages.items.map(\.id) == [100, 101, 102])
    #expect(messages.items[2].isReaction == true)
    #expect(messages.items[2].reactedToGuid == "guid-101")
    #expect(messages.items[2].reactionType == "love")
    #expect(messages.items[2].isReactionAdd == true)
    #expect(try await store.messages(chatID: 1).items.map(\.id) == [100, 101])
}

@Test
func receiptsAppearOnlyOnOutgoingMessages() async throws {
    let fixture = try MessageDatabaseFixture()
    let store = fixture.makeStore()

    let messages = try await store.messages(chatID: 1)
    let incoming = try #require(messages.items.first { $0.id == 100 })
    let outgoing = try #require(messages.items.first { $0.id == 101 })
    #expect(incoming.deliveredAt == nil)
    #expect(incoming.readAt == nil)
    #expect(outgoing.deliveredAt != nil)
    #expect(outgoing.readAt != nil)

    let outgoingHit = try #require(try await store.messages(chatID: 1, query: "hi there").items.first)
    #expect(outgoingHit.id == 101)
    #expect(outgoingHit.deliveredAt != nil)
    #expect(outgoingHit.readAt != nil)

    let incomingHit = try #require(try await store.messages(chatID: 1, query: "hello").items.first)
    #expect(incomingHit.id == 100)
    #expect(incomingHit.deliveredAt == nil)
}

@Test
func retrievalPathsUseTheSameReactionBoundaries() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, is_from_me, date, associated_message_type)
        VALUES
            (103, 'guid-103', 'matching associated', 0, 700000180, 3),
            (104, 'guid-104', 'matching below reaction range', 0, 700000240, 1999),
            (105, 'guid-105', 'matching reaction add', 0, 700000300, 2000),
            (106, 'guid-106', 'matching reaction remove', 0, 700000360, 3006),
            (107, 'guid-107', 'matching above reaction range', 0, 700000420, 3007);
        INSERT INTO chat_message_join (chat_id, message_id)
        VALUES (1, 103), (1, 104), (1, 105), (1, 106), (1, 107);
        """)
    let store = fixture.makeStore()

    #expect(try await store.messages(chatID: 1).items.map(\.id) == [100, 101, 103, 104, 107])
    #expect(try await store.messages(chatID: 1, query: "matching").items.map(\.id) == [103, 104, 107])

    let reactions = try await store.messages(chatID: 1, includeReactions: true)
    #expect(reactions.items.first { $0.id == 105 }?.isReactionAdd == true)
    #expect(reactions.items.first { $0.id == 106 }?.isReactionAdd == false)
}

@Test
func historyTreatsNullAssociatedTypeAsOrdinaryMessage() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, is_from_me, date, associated_message_type)
        VALUES (103, 'guid-103', 'ordinary', 0, 700000180, NULL);
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 103);
        """)

    let messages = try await fixture.makeStore().messages(chatID: 1)
    #expect(messages.items.map(\.id) == [100, 101, 103])
}

@Test
func historySearchEscapesLikeWildcards() async throws {
    let fixture = try MessageDatabaseFixture()
    let store = fixture.makeStore()

    let hits = try await store.messages(chatID: 1, query: "hello")
    #expect(hits.items.count == 1)
    #expect(hits.items[0].guid == "guid-100")
    #expect(try await store.messages(chatID: 1, query: "%").items.isEmpty)
}

@Test
func filteredHistoryPagesTraverseOlderRowsAndRemainChronological() async throws {
    let fixture = try MessageDatabaseFixture(seedData: false)
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name) VALUES
            (1, 'chat-1', 'one', 'iMessage'),
            (2, 'chat-2', 'two', 'iMessage');
        INSERT INTO message (ROWID, guid, text, is_from_me, is_read, date) VALUES
            (101, 'message-1', 'needle one', 0, 1, 700000000),
            (102, 'message-2', 'needle two', 0, 1, 700000000),
            (103, 'message-3', 'needle three', 0, 1, 699999000),
            (104, 'message-4', 'needle four', 0, 1, NULL),
            (105, 'message-5', 'needle five', 0, 1, NULL);
        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (1, 101), (1, 102), (1, 103), (1, 104), (1, 105), (2, 102);
        """)
    let store = fixture.makeStore()
    var cursor: String?
    var ids: [Int64] = []

    repeat {
        let page = try await store.messages(chatID: 1, limit: 2, cursor: cursor, query: "needle")
        #expect(page.items.map(\.id) == page.items.map(\.id).sorted())
        ids += page.items.map(\.id)
        #expect(page.hasMore == (page.nextCursor != nil))
        cursor = page.nextCursor
    } while cursor != nil

    #expect(ids == [104, 105, 102, 103, 101])
    #expect(Set(ids).count == 5)
}

@Test
func historyCursorIsBoundToChatQueryMatchAndOptions() async throws {
    let fixture = try MessageDatabaseFixture()
    let store = fixture.makeStore()
    try fixture.execute("""
        INSERT INTO message (ROWID, guid, text, is_from_me, is_read, date)
        VALUES (103, 'guid-103', 'hello again', 0, 1, 699999000);
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 103);
        """)
    let cursor = try #require(try await store.messages(chatID: 1, limit: 1, query: "hello").nextCursor)

    await #expect(throws: MessageStore.StoreError.self) {
        try await store.messages(chatID: 2, limit: 1, cursor: cursor, query: "hello")
    }
    await #expect(throws: MessageStore.StoreError.self) {
        try await store.messages(chatID: 1, limit: 1, cursor: cursor, query: "different")
    }
    await #expect(throws: MessageStore.StoreError.self) {
        try await store.messages(chatID: 1, limit: 1, cursor: cursor, query: "hello", exactMatch: true)
    }
    await #expect(throws: MessageStore.StoreError.self) {
        try await store.messages(chatID: 1, limit: 1, cursor: cursor, includeAttachments: true, query: "hello")
    }
}
