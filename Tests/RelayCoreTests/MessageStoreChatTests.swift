import Testing
import Foundation

@testable import RelayCore

@Test
func chatsListParticipantsAndMetadata() async throws {
    let fixture = try MessageDatabaseFixture()
    let chats = try await fixture.makeStore().chats().items
    let chat = try #require(chats.first)

    #expect(chats.count == 1)
    #expect(chat.id == 1)
    #expect(chat.identifier == "+15551230001")
    #expect(chat.participants == ["+15551230001"])
    #expect(!chat.isGroup)
    #expect(chat.displayName == nil)
    #expect(chat.name == chat.identifier)
}

@Test
func chatDetailReturnsOneChatWithoutPagingAndMissingIsNil() async throws {
    let fixture = try MessageDatabaseFixture()
    let store = fixture.makeStore()

    let chat = try #require(try await store.chat(id: 1))
    #expect(chat.id == 1)
    #expect(chat.participants == ["+15551230001"])
    #expect(try await store.chat(id: 999) == nil)
}

@Test
func chatsFilterUnreadState() async throws {
    let unreadFixture = try MessageDatabaseFixture(unreadInChat1: true)
    let unreadStore = unreadFixture.makeStore()
    #expect(try await unreadStore.chats(unreadOnly: true).items.count == 1)
    #expect(try await unreadStore.chats().items.count == 1)

    let readFixture = try MessageDatabaseFixture()
    let readStore = readFixture.makeStore()
    #expect(try await readStore.chats(unreadOnly: true).items.isEmpty)
    #expect(try await readStore.chats().items.count == 1)
}

@Test
func sendTargetSeparatesChatGUIDFromRecipients() async throws {
    let fixture = try MessageDatabaseFixture()
    let target = try #require(try await fixture.makeStore().sendTarget(chatID: 1))

    #expect(target.chatGuid == "iMessage;-;+15551230001")
    #expect(target.recipients == ["+15551230001"])
}

@Test
func groupSendTargetDoesNotFallBackToGroupIdentifier() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
        VALUES (2, 'iMessage;+;group-id', 'group-id;+;', 'iMessage');
        """)

    let target = try #require(try await fixture.makeStore().sendTarget(chatID: 2))
    #expect(target.chatGuid == "iMessage;+;group-id")
    #expect(target.recipients.isEmpty)
}

@Test
func chatPagesTraverseEqualAndNullDatesWithoutDuplicates() async throws {
    let fixture = try MessageDatabaseFixture(seedData: false)
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name) VALUES
            (1, 'chat-1', 'one', 'iMessage'),
            (2, 'chat-2', 'two', 'iMessage'),
            (3, 'chat-3', 'three', 'iMessage'),
            (4, 'chat-4', 'four', 'iMessage'),
            (5, 'chat-5', 'five', 'iMessage');
        INSERT INTO message (ROWID, guid, text, is_from_me, is_read, date) VALUES
            (101, 'message-1', 'first', 0, 1, 700000000),
            (102, 'message-2', 'second', 0, 1, 700000000),
            (103, 'message-3', 'third', 0, 1, 699999000);
        INSERT INTO chat_message_join (chat_id, message_id) VALUES
            (1, 101), (2, 102), (3, 103);
        """)
    let store = fixture.makeStore()
    var cursor: String?
    var ids: [Int64] = []

    repeat {
        let page = try await store.chats(limit: 2, cursor: cursor)
        ids += page.items.map(\.id)
        #expect(page.hasMore == (page.nextCursor != nil))
        cursor = page.nextCursor
    } while cursor != nil

    #expect(ids == [2, 1, 3, 5, 4])
    #expect(Set(ids).count == 5)
    let emptyPage = try await store.chats(limit: 2, unreadOnly: true)
    #expect(emptyPage.items.isEmpty)
    #expect(!emptyPage.hasMore)
}

@Test
func chatCursorPreservesExactIntegerNanosecondDates() async throws {
    var options = MessageDatabaseFixture.SchemaOptions()
    options.dateStorageType = "INTEGER"
    let fixture = try MessageDatabaseFixture(options: options, seedData: false)
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name) VALUES
            (1, 'chat-1', 'one', 'iMessage'),
            (2, 'chat-2', 'two', 'iMessage'),
            (3, 'chat-3', 'three', 'iMessage');
        INSERT INTO message (ROWID, guid, text, is_from_me, is_read, date) VALUES
            (101, 'message-101', 'one', 0, 1, 700000000000000001),
            (102, 'message-102', 'two', 0, 1, 700000000000000001),
            (103, 'message-103', 'three', 0, 1, 700000000000000000);
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 101), (2, 102), (3, 103);
        """)
    let store = fixture.makeStore()
    var cursor: String?
    var ids: [Int64] = []

    repeat {
        let page = try await store.chats(limit: 1, cursor: cursor)
        ids += page.items.map(\.id)
        cursor = page.nextCursor
    } while cursor != nil

    #expect(ids == [2, 1, 3])
}

@Test
func chatPageCursorsRejectMalformedVersionRouteAndDatabase() async throws {
    let fixture = try MessageDatabaseFixture()
    let store = fixture.makeStore()
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
        VALUES (2, 'chat-2', 'two', 'iMessage');
        """)
    let valid = try #require(try await store.chats(limit: 1).nextCursor)
    let wrongVersion = Data(#"{"fingerprint":"unused","kind":"chats","rowid":1,"version":2}"#.utf8)
        .base64EncodedString()

    await #expect(throws: MessageStore.StoreError.self) { try await store.chats(cursor: "not-base64") }
    await #expect(throws: MessageStore.StoreError.self) { try await store.chats(cursor: wrongVersion) }
    await #expect(throws: MessageStore.StoreError.self) {
        try await store.messages(chatID: 1, cursor: valid)
    }

    let replacement = try MessageDatabaseFixture()
    await #expect(throws: MessageStore.StoreError.self) {
        try await replacement.makeStore().chats(cursor: valid)
    }
}
