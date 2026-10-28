import Foundation
import Testing

@testable import RelayCore

@Test(arguments: [false, true], [false, true])
func currentEditsNeverReturnStalePlainText(validBody: Bool, global: Bool) async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("ALTER TABLE message ADD COLUMN date_edited INTEGER;")
    try fixture.execute("UPDATE message SET text = 'stale original', date_edited = 700000010000000000 WHERE ROWID = 100;")
    let body = validBody
        ? try MessageDatabaseFixture.archivedAttributedString(NSAttributedString(string: "Corrected café"))
        : Data([0, 1, 2])
    try fixture.setAttributedBody(messageRowID: 100, data: body)
    let storage = fixture.makeStorage()
    let id = try MessageID(validating: MessageDatabaseFixture.rootMessageID)
    let message = try #require(try await storage.messages.message(id: id))
    #expect(message.text == (validBody ? "Corrected café" : nil))
    #expect(message.editedAt != nil)
    #expect(message.unsentAt == nil)
    let page = try await storage.messages.listMessages(
        conversationID: global ? nil : ConversationID(validating: MessageDatabaseFixture.oneToOneID),
        options: MessageListOptions(search: validBody ? "corrected cafe" : "stale original", searchMode: .exact)
    )
    #expect(page.items.contains { $0.id == id } == validBody)
    let object = try #require(JSONSerialization.jsonObject(with: RelayJSON.encoder.encode(message)) as? [String: Any])
    #expect(object["edited_at"] is String)
    #expect(object["unsent_at"] == nil)
    try await storage.shutdown()
}

@Test
func unsentMessagesKeepIdentityWithoutBodyPartsOrAttachments() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("ALTER TABLE message ADD COLUMN date_retracted INTEGER;")
    let storage = fixture.makeStorage()
    let id = try MessageID(validating: "00000000-0000-0000-0000-000000000102")
    let mediaID = try MediaID(validating: MessageDatabaseFixture.attachmentID)
    #expect(try await storage.media.media(id: mediaID) != nil)
    try fixture.execute("UPDATE message SET date_retracted = 700000020000000000 WHERE ROWID = 102;")
    let message = try #require(try await storage.messages.message(id: id))
    #expect(message.id == id)
    #expect(message.text == nil)
    #expect(message.parts == [])
    #expect(message.attachments.isEmpty)
    #expect(message.unsentAt != nil)
    #expect(try await storage.media.media(id: mediaID) == nil)
    let page = try await storage.messages.listMessages(
        conversationID: ConversationID(validating: MessageDatabaseFixture.oneToOneID),
        options: MessageListOptions(includeAttachments: true)
    )
    let listed = try #require(page.items.first { $0.id == id })
    #expect(listed.text == nil)
    #expect(listed.parts == [])
    #expect(listed.attachments.isEmpty)
    let roundTrip = try RelayJSON.decoder.decode(Message.self, from: RelayJSON.encoder.encode(message))
    #expect(roundTrip == message)
    try await storage.shutdown()
}

@Test
func missingMutationColumnsPreserveOrdinaryMessages() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let message = try #require(try await storage.messages.message(
        id: MessageID(validating: MessageDatabaseFixture.rootMessageID)
    ))
    #expect(message.text != nil)
    #expect(message.editedAt == nil)
    #expect(message.unsentAt == nil)
    try await storage.shutdown()
}
