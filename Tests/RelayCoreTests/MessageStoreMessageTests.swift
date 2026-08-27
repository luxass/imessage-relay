import Testing

@testable import RelayCore

@Test
func historyHidesReactionsAndReturnsChronologicalRows() throws {
    let fixture = try MessageDatabaseFixture()
    let messages = try fixture.makeStore().messages(chatID: 1)

    #expect(messages.map(\.id) == [100, 101])
    #expect(messages[0].text == "hello")
    #expect(!messages[0].isFromMe)
    #expect(messages[1].isFromMe)
}

@Test
func historyCanIncludeReactionEvents() throws {
    let fixture = try MessageDatabaseFixture()
    let store = try fixture.makeStore()
    let messages = try store.messages(chatID: 1, includeReactions: true)

    #expect(messages.map(\.id) == [100, 101, 102])
    #expect(messages[2].isReaction == true)
    #expect(messages[2].reactedToGuid == "guid-101")
    #expect(messages[2].reactionType == "love")
    #expect(messages[2].isReactionAdd == true)
    #expect(try store.messages(chatID: 1).map(\.id) == [100, 101])
}

@Test
func receiptsAppearOnlyOnOutgoingMessages() throws {
    let fixture = try MessageDatabaseFixture()
    let store = try fixture.makeStore()

    for messages in [
        try store.messages(chatID: 1),
        try store.messagesAfter(sinceRowid: 99).messages,
    ] {
        let incoming = try #require(messages.first { $0.id == 100 })
        let outgoing = try #require(messages.first { $0.id == 101 })
        #expect(incoming.deliveredAt == nil)
        #expect(incoming.readAt == nil)
        #expect(outgoing.deliveredAt != nil)
        #expect(outgoing.readAt != nil)
    }

    let outgoingHit = try #require(try store.search(query: "hi there").first)
    #expect(outgoingHit.id == 101)
    #expect(outgoingHit.deliveredAt != nil)
    #expect(outgoingHit.readAt != nil)

    let incomingHit = try #require(try store.search(query: "hello").first)
    #expect(incomingHit.id == 100)
    #expect(incomingHit.deliveredAt == nil)
}

@Test
func cursorAdvancesPastSuppressedReactionRows() throws {
    let fixture = try MessageDatabaseFixture()
    let store = try fixture.makeStore()

    let page = try store.messagesAfter(sinceRowid: 99)
    #expect(page.messages.map(\.id) == [100, 101])
    #expect(page.nextRowid == 102)
    #expect(!page.hasMore)

    let withReactions = try store.messagesAfter(sinceRowid: 99, includeReactions: true)
    #expect(withReactions.messages.map(\.id) == [100, 101, 102])
    #expect(withReactions.messages[2].isReaction == true)
    #expect(withReactions.messages[2].reactedToGuid == "guid-101")
    #expect(withReactions.messages[2].reactionType == "love")
    #expect(withReactions.messages[2].isReactionAdd == true)
}

@Test
func cursorKeepsNonReactionAssociatedRows() throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, is_from_me, date, associated_message_type)
        VALUES (103, 'guid-103', 'payment request', 0, 700000180, 3);
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 103);
        """)

    let page = try fixture.makeStore().messagesAfter(sinceRowid: 102)
    #expect(page.messages.map(\.id) == [103])
    #expect(page.messages[0].isReaction == nil)
}

@Test
func globalCursorDeduplicatesMessagesJoinedToMultipleChats() throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
        VALUES (2, 'iMessage;-;+15551230002', '+15551230002', 'iMessage');
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (2, 100);
        """)

    let page = try fixture.makeStore().messagesAfter(sinceRowid: 99, limit: 10)
    #expect(page.messages.map(\.id) == [100, 101])
    #expect(page.nextRowid == 102)
}

@Test
func historyTreatsNullAssociatedTypeAsOrdinaryMessage() throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, is_from_me, date, associated_message_type)
        VALUES (103, 'guid-103', 'ordinary', 0, 700000180, NULL);
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 103);
        """)

    let messages = try fixture.makeStore().messages(chatID: 1)
    #expect(messages.map(\.id) == [100, 101, 103])
}

@Test
func searchEscapesLikeWildcards() throws {
    let fixture = try MessageDatabaseFixture()
    let store = try fixture.makeStore()

    let hits = try store.search(query: "hello")
    #expect(hits.count == 1)
    #expect(hits[0].guid == "guid-100")
    #expect(try store.search(query: "%").isEmpty)
}
