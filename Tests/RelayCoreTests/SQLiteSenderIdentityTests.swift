import Testing

@testable import RelayCore

@Test(arguments: [false, true], [String?.none, "", "+15005550007", "local@example.com"])
func storedSenderIdentityUsesDirectionAndLocalAccount(isFromMe: Bool, local: String?) async throws {
    let fixture = try MessageDatabaseFixture(seedData: false)
    try fixture.execute("ALTER TABLE message ADD COLUMN destination_caller_id TEXT;")
    let localValue = local.map { "'\($0)'" } ?? "NULL"
    let direction = isFromMe ? 1 : 0
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
        VALUES (1, 'sender-chat', 'peer@example.com', 'iMessage');
        INSERT INTO handle (ROWID, id, service) VALUES (10, 'peer@example.com', 'iMessage');
        INSERT INTO message
            (ROWID, guid, handle_id, is_from_me, date, associated_message_type,
             associated_message_guid, destination_caller_id)
        VALUES
            (1, 'sender-message', 10, \(direction), 700000000000000000, 0, NULL, \(localValue)),
            (2, 'sender-reaction', 10, \(direction), 700000001000000000, 2001, 'p:0/sender-message', \(localValue));
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 1), (1, 2);
        """)
    let storage = fixture.makeStorage()
    let message = try #require(try await storage.messages.message(id: MessageID(validating: "sender-message")))
    let expected = isFromMe ? local.flatMap { $0.isEmpty ? nil : $0 } : "peer@example.com"
    #expect(message.sender?.value == expected)
    #expect(message.reactions.count == 1)
    #expect(message.reactions.first?.sender?.value == expected)
    try await storage.shutdown()
}

@Test
func outgoingSenderIsUnknownWithoutLocalAccountColumns() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let message = try #require(try await storage.messages.message(
        id: MessageID(validating: "00000000-0000-0000-0000-000000000101")
    ))
    #expect(message.isFromMe)
    #expect(message.sender == nil)
    try await storage.shutdown()
}
