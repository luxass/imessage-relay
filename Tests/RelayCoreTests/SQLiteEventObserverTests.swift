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

@Test
func sqliteObserverUsesFilesystemChangesBeforeTheFallbackPoll() async throws {
    let fixture = try MessageDatabaseFixture()
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .seconds(30)
    )
    let ready = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let eventTask = Task { () throws -> RelayEvent? in
        var iterator = observer.events().makeAsyncIterator()
        guard case .streamReady = try await iterator.next() else {
            return nil
        }
        ready.continuation.yield()
        ready.continuation.finish()
        return try await nextEvent(of: .messageCreated, from: &iterator)
    }

    for await _ in ready.stream { break }
    try insertObservedMessage(into: fixture)

    let event = try await value(of: eventTask, timeout: .seconds(3))
    guard case .messageCreated(let payload) = event else {
        Issue.record("Expected a message.created event from the filesystem notification.")
        return
    }
    #expect(payload.messageID.rawValue == "event-message-guid")
    try await observer.shutdown()
}

@Test
func sqliteObserverReopensAfterDatabaseReplacement() async throws {
    let fixture = try MessageDatabaseFixture()
    let replacement = try MessageDatabaseFixture()
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10)
    )
    var firstIterator = observer.events().makeAsyncIterator()
    let firstEvent = try #require(try await firstIterator.next())
    guard case .streamReady(let firstReady) = firstEvent else {
        Issue.record("Expected the first stream to become ready.")
        return
    }

    try FileManager.default.removeItem(atPath: fixture.path)
    try FileManager.default.moveItem(atPath: replacement.path, toPath: fixture.path)

    let reset = try #require(try await nextEvent(of: .streamReset, from: &firstIterator))
    guard case .streamReset(let resetPayload) = reset else {
        Issue.record("Expected a database replacement reset.")
        return
    }
    #expect(resetPayload.reason == .databaseChanged)

    var secondIterator = observer.events().makeAsyncIterator()
    let secondEvent = try #require(try await secondIterator.next())
    guard case .streamReady(let secondReady) = secondEvent else {
        Issue.record("Expected the replacement database stream to become ready.")
        return
    }
    #expect(secondReady.databaseIdentity != firstReady.databaseIdentity)
    try await observer.shutdown()
}

@Test
func sqliteFileMonitorWatchesASidecarCreatedAfterStartup() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-file-watch-create-\(UUID().uuidString)", isDirectory: true)
    let databaseDirectory = root.appendingPathComponent("messages", isDirectory: true)
    try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let database = databaseDirectory.appendingPathComponent("chat.db")
    let writeAheadLog = URL(fileURLWithPath: database.path + "-wal")
    FileManager.default.createFile(atPath: database.path, contents: Data())

    let changes = FileChangeCounter()
    let monitor = SQLiteFileChangeMonitor(
        path: database.path,
        debounceInterval: 0.01
    ) {
        changes.increment()
    }
    monitor.start()
    defer { monitor.stop() }

    FileManager.default.createFile(atPath: writeAheadLog.path, contents: Data())
    try await waitForChange(after: 0, in: changes)
    try await Task.sleep(for: .milliseconds(100))
    let countAfterCreation = changes.value

    let handle = try FileHandle(forWritingTo: writeAheadLog)
    try handle.write(contentsOf: Data("change".utf8))
    try handle.close()

    try await waitForChange(after: countAfterCreation, in: changes)
}

@Test
func sqliteFileMonitorRearmsAReplacedSidecar() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-file-watch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = directory.appendingPathComponent("chat.db")
    let writeAheadLog = URL(fileURLWithPath: database.path + "-wal")
    let sharedMemory = URL(fileURLWithPath: database.path + "-shm")
    FileManager.default.createFile(atPath: database.path, contents: Data())
    FileManager.default.createFile(atPath: writeAheadLog.path, contents: Data())
    FileManager.default.createFile(atPath: sharedMemory.path, contents: Data())

    let changes = FileChangeCounter()
    let monitor = SQLiteFileChangeMonitor(path: database.path, debounceInterval: 0.01) {
        changes.increment()
    }
    monitor.start()
    defer { monitor.stop() }

    try FileManager.default.moveItem(
        at: writeAheadLog,
        to: directory.appendingPathComponent("chat.db-wal.old")
    )
    FileManager.default.createFile(atPath: writeAheadLog.path, contents: Data())
    try await waitForChange(after: 0, in: changes)
    try await Task.sleep(for: .milliseconds(100))
    let countAfterReplacement = changes.value

    let handle = try FileHandle(forWritingTo: writeAheadLog)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("change".utf8))
    try handle.close()

    try await waitForChange(after: countAfterReplacement, in: changes)
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

private struct EventTimeout: Error {}

private func value<Value: Sendable>(
    of task: Task<Value, any Error>,
    timeout: Duration
) async throws -> Value {
    defer { task.cancel() }
    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await task.value }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw EventTimeout()
        }
        guard let result = try await group.next() else { throw EventTimeout() }
        group.cancelAll()
        return result
    }
}

private final class FileChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private func waitForChange(
    after previousValue: Int,
    in counter: FileChangeCounter
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while counter.value <= previousValue {
        guard clock.now < deadline else { throw EventTimeout() }
        try await clock.sleep(for: .milliseconds(10))
    }
}
