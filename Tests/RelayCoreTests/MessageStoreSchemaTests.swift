import Testing

@testable import RelayCore

@Test
func missingOptionalColumnsUseSafeDefaults() async throws {
    let fixture = try MessageDatabaseFixture(
        options: .init(
            includeReadState: false,
            includeReactions: false,
            includeReplies: false,
            includeReceipts: false,
            includeAttachmentMetadata: false
        ),
        seedData: false
    )
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
        VALUES (1, 'iMessage;-;+15551230001', '+15551230001', 'iMessage');
        INSERT INTO message (ROWID, guid, text, is_from_me, date)
        VALUES (100, 'guid-100', 'hello', 0, 700000000);
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 100);
        INSERT INTO attachment (ROWID, filename) VALUES (700, '/missing/photo.jpg');
        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (100, 700);
        """)

    let store = fixture.makeStore()
    let messages = try await store.messages(chatID: 1, includeAttachments: true)
    let message = try #require(messages.items.first)
    let attachment = try #require(message.attachments.first)

    #expect(message.text == "hello")
    #expect(message.replyToGuid == nil)
    #expect(message.deliveredAt == nil)
    #expect(message.isReaction == nil)
    #expect(attachment.id == 700)
    #expect(attachment.mimeType.isEmpty)
    #expect(attachment.totalBytes == 0)
    #expect(!attachment.isSticker)
    #expect(try await store.chats().items.first?.unreadCount == 0)
}
