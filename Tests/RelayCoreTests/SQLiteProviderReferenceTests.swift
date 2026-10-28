import Foundation
import Testing

@testable import RelayCore

@Test(arguments: [
    (String?.none, String?.none),
    (.some("MESSAGE-ID"), .some("MESSAGE-ID")),
    (.some("p:0/MESSAGE-ID"), .some("MESSAGE-ID")),
    (.some("p:3/MESSAGE-ID"), .some("MESSAGE-ID")),
    (.some("bp:MESSAGE-ID"), .some("MESSAGE-ID")),
    (.some("p:0/MESSAGE-ID/CHILD"), .some("MESSAGE-ID/CHILD")),
    (.some("unrecognized/MESSAGE-ID"), .some("unrecognized/MESSAGE-ID")),
    (.some("p:missing-slash"), .some("p:missing-slash")),
    (.some("P:0/MESSAGE-ID"), .some("P:0/MESSAGE-ID")),
    (.some("bp:0/MESSAGE-ID"), .some("0/MESSAGE-ID")),
])
func providerReferencesPreserveTargetsInPollReadsAndObservedReactions(
    reference: String?,
    expected: String?
) async throws {
    let fixture = try providerReferenceFixture(reference)
    let storage = fixture.makeStorage()
    let vote = try #require(try await storage.messages.message(id: MessageID(validating: "vote-message")))
    #expect(vote.poll?.kind == .vote)
    #expect(vote.poll?.originalMessageID?.rawValue == expected)

    let database = try SQLiteDatabase(path: fixture.path)
    let candidates = try SQLiteEventSnapshotStore.refreshMessageCandidates(database: database, rowIDs: [2])
    #expect(candidates.count == 1)
    let candidate = try #require(candidates.first)
    #expect(candidate.rowID == 2)
    #expect(candidate.message == nil)
    #expect(candidate.reaction?.messageID.rawValue == expected)

    try await storage.shutdown()
}

@Test(arguments: ["", "p:0/", "bp:"])
func emptyProviderTargetsRetainReadValidationAndAreNotObserved(reference: String) async throws {
    let fixture = try providerReferenceFixture(reference)
    let storage = fixture.makeStorage()
    await #expect(throws: IdentifierValidationError.empty) {
        _ = try await storage.messages.message(id: MessageID(validating: "vote-message"))
    }

    let database = try SQLiteDatabase(path: fixture.path)
    let candidates = try SQLiteEventSnapshotStore.refreshMessageCandidates(database: database, rowIDs: [2])
    #expect(candidates.count == 1)
    let candidate = try #require(candidates.first)
    #expect(candidate.rowID == 2)
    #expect(candidate.message == nil)
    #expect(candidate.reaction == nil)

    try await storage.shutdown()
}

private func providerReferenceFixture(_ reference: String?) throws -> MessageDatabaseFixture {
    let fixture = try MessageDatabaseFixture(seedData: false)
    let storedReference = reference.map { "'\($0)'" } ?? "NULL"
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
        VALUES (1, 'reference-chat', 'person@example.com', 'iMessage');
        INSERT INTO message
            (ROWID, guid, text, is_from_me, date, associated_message_guid, associated_message_type)
        VALUES
            (1, 'vote-message', NULL, 0, 700000000000000000, \(storedReference), 4000),
            (2, 'reaction-message', NULL, 0, 700000001000000000, \(storedReference), 2001);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES (1, 1, 700000000000000000, 0), (1, 2, 700000001000000000, 0);
        """)
    return fixture
}
