import Foundation
import Testing

@testable import RelayCore

@Test
func sqliteObserverEmitsCreatedUpdatedReactionAndMediaEvents() async throws {
    let fixture = try MessageDatabaseFixture()
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10)
    )
    var iterator = observer.events().makeAsyncIterator()

    let ready = try #require(try await iterator.next())
    guard case .streamReady(let readyPayload) = ready else {
        Issue.record("Expected stream.ready as the first event.")
        return
    }
    #expect(readyPayload.replaySupported == false)

    try insertObservedMessage(into: fixture)

    let created = try #require(try await nextEvent(of: .messageCreated, from: &iterator))
    guard case .messageCreated(let createdPayload) = created else {
        Issue.record("Expected message.created.")
        return
    }
    #expect(createdPayload.messageID.rawValue == "event-message-guid")
    #expect(createdPayload.conversationID.rawValue == MessageDatabaseFixture.oneToOneID)
    #expect(createdPayload.isFromMe == false)

    try markObservedMessageDeliveredAndRead(in: fixture)

    let updated = try #require(try await nextEvent(of: .messageUpdated, from: &iterator))
    guard case .messageUpdated(let updatedPayload) = updated else {
        Issue.record("Expected message.updated.")
        return
    }
    #expect(updatedPayload.changedFields == [.deliveryState, .readState])

    try insertReaction(into: fixture, rowID: 301, guid: "event-reaction-guid", type: 2000)

    let reaction = try #require(try await nextEvent(of: .reactionAdded, from: &iterator))
    guard case .reactionAdded(let reactionPayload) = reaction else {
        Issue.record("Expected reaction.added.")
        return
    }
    #expect(reactionPayload.messageID.rawValue == "event-message-guid")
    #expect(reactionPayload.reactionID.rawValue == "event-reaction-guid")

    try insertReaction(
        into: fixture,
        rowID: 302,
        guid: "event-reaction-removal-guid",
        type: 3000
    )

    let removal = try #require(try await nextEvent(of: .reactionRemoved, from: &iterator))
    guard case .reactionRemoved(let removalPayload) = removal else {
        Issue.record("Expected reaction.removed.")
        return
    }
    #expect(removalPayload.reactionID.rawValue == "event-reaction-removal-guid")

    let pendingAttachment = try attachUnavailableMedia(to: fixture)
    try fixture.execute("UPDATE message SET is_read = 0, date_read = 0 WHERE ROWID = 300;")
    _ = try #require(try await nextEvent(of: .messageUpdated, from: &iterator))
    try Data("event attachment".utf8).write(to: pendingAttachment)

    let media = try #require(try await nextEvent(of: .mediaAvailable, from: &iterator))
    guard case .mediaAvailable(let mediaPayload) = media else {
        Issue.record("Expected media.available.")
        return
    }
    #expect(mediaPayload.messageID.rawValue == "event-message-guid")
    #expect(mediaPayload.mediaID.rawValue == "event-attachment-guid")

    try await observer.shutdown()
}

private func insertObservedMessage(into fixture: MessageDatabaseFixture) throws {
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, error, is_sent,
             is_delivered, is_read, date_delivered, date_read, reply_to_guid,
             thread_originator_guid, part_count, associated_message_guid,
             associated_message_type, associated_message_emoji, item_type,
             is_finished, is_system_message)
        VALUES
            (300, 'event-message-guid', 'Event fixture', 10, 0, 700000500000000000,
             0, 0, 0, 0, 0, 0, NULL, NULL, 1, NULL, 0, NULL, 0, 1, 0);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES (1, 300, 700000500000000000, 0);
        """)
}

private func markObservedMessageDeliveredAndRead(in fixture: MessageDatabaseFixture) throws {
    try fixture.execute("""
        UPDATE message
        SET is_from_me = 1, is_sent = 1, is_delivered = 1, is_read = 1,
            date_delivered = 700000510000000000, date_read = 700000520000000000
        WHERE ROWID = 300;
        """)
}

private func insertReaction(
    into fixture: MessageDatabaseFixture,
    rowID: Int,
    guid: String,
    type: Int
) throws {
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, error, is_sent,
             is_delivered, is_read, date_delivered, date_read, reply_to_guid,
             thread_originator_guid, part_count, associated_message_guid,
             associated_message_type, associated_message_emoji, item_type,
             is_finished, is_system_message)
        VALUES
            (\(rowID), '\(guid)', NULL, 10, 0, 700000530000000000,
             0, 0, 0, 1, 0, 0, NULL, NULL, 1, 'p:0/event-message-guid',
             \(type), NULL, 0, 1, 0);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES (1, \(rowID), 700000530000000000, 0);
        """)
}

private func attachUnavailableMedia(to fixture: MessageDatabaseFixture) throws -> URL {
    let attachmentURL = fixture.attachmentDirectory.appendingPathComponent("event-photo.jpg")
    let escapedPath = attachmentURL.path.replacingOccurrences(of: "'", with: "''")
    try fixture.execute("""
        INSERT INTO attachment
            (ROWID, guid, original_guid, filename, transfer_name, mime_type, uti, total_bytes)
        VALUES
            (303, 'event-attachment-guid', 'event-original-guid', '\(escapedPath)',
             'event-photo.jpg', 'image/jpeg', 'public.jpeg', 16);
        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (300, 303);
        """)
    return attachmentURL
}

private func nextEvent(
    of type: RelayEventType,
    from iterator: inout AsyncThrowingStream<RelayEvent, any Error>.Iterator
) async throws -> RelayEvent? {
    while let event = try await iterator.next() {
        if event.type == type { return event }
    }
    return nil
}
