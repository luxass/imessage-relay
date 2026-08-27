import Testing

@testable import RelayCore

@Test
func chatsListParticipantsAndMetadata() throws {
    let fixture = try MessageDatabaseFixture()
    let chats = try fixture.makeStore().chats()
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
func chatsFilterUnreadState() throws {
    let unreadFixture = try MessageDatabaseFixture(unreadInChat1: true)
    let unreadStore = try unreadFixture.makeStore()
    #expect(try unreadStore.chats(unreadOnly: true).count == 1)
    #expect(try unreadStore.chats().count == 1)

    let readFixture = try MessageDatabaseFixture()
    let readStore = try readFixture.makeStore()
    #expect(try readStore.chats(unreadOnly: true).isEmpty)
    #expect(try readStore.chats().count == 1)
}

@Test
func sendTargetSeparatesChatGUIDFromRecipients() throws {
    let fixture = try MessageDatabaseFixture()
    let target = try #require(try fixture.makeStore().sendTarget(chatID: 1))

    #expect(target.chatGuid == "iMessage;-;+15551230001")
    #expect(target.recipients == ["+15551230001"])
}

@Test
func groupSendTargetDoesNotFallBackToGroupIdentifier() throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
        VALUES (2, 'iMessage;+;group-id', 'group-id;+;', 'iMessage');
        """)

    let target = try #require(try fixture.makeStore().sendTarget(chatID: 2))
    #expect(target.chatGuid == "iMessage;+;group-id")
    #expect(target.recipients.isEmpty)
}
