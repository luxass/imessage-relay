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
func sqliteObserverFindsBooleanOnlyUpdatesThroughBoundedRechecks() async throws {
    let fixture = try MessageDatabaseFixture()
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10),
        reconciliationInterval: .seconds(30)
    )
    var iterator = observer.events().makeAsyncIterator()
    guard case .streamReady = try await iterator.next() else {
        Issue.record("Expected stream.ready as the first event.")
        return
    }

    try fixture.execute("UPDATE message SET is_read = 1, date_read = 0 WHERE ROWID = 100")
    let event = try #require(try await nextEvent(of: .messageUpdated, from: &iterator))
    guard case .messageUpdated(let payload) = event else {
        Issue.record("Expected message.updated.")
        return
    }
    #expect(payload.messageID.rawValue == MessageDatabaseFixture.rootMessageID)
    #expect(payload.changedFields == [.readState])
    #expect(observer.diagnostics.incrementalBatches > 0)
    #expect(observer.diagnostics.reconciliations == 0)
    try await observer.shutdown()
}

@Test
func sqliteObserverDoesNotSkipReadUpdatesWithEqualTimestamps() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("CREATE INDEX message_date_read_test ON message(date_read)")
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, is_read, date_read,
             associated_message_type)
        VALUES
            (410, 'equal-read-a', 'A', 10, 0, 700000610000000000, 0, 0, 0),
            (411, 'equal-read-b', 'B', 10, 0, 700000611000000000, 0, 0, 0);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES
            (1, 410, 700000610000000000, 0),
            (1, 411, 700000611000000000, 0)
        """)
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10),
        reconciliationInterval: .seconds(30)
    )
    var iterator = observer.events().makeAsyncIterator()
    guard case .streamReady = try await iterator.next() else {
        Issue.record("Expected stream.ready as the first event.")
        return
    }

    try fixture.execute("""
        UPDATE message
        SET is_read = 1, date_read = 800000000000000000
        WHERE ROWID IN (410, 411)
        """)
    var updated: Set<String> = []
    while updated.count < 2 {
        let event = try #require(try await iterator.next())
        if case .messageUpdated(let payload) = event,
           payload.messageID.rawValue.hasPrefix("equal-read-") {
            updated.insert(payload.messageID.rawValue)
        }
    }
    #expect(updated == ["equal-read-a", "equal-read-b"])
    #expect(observer.diagnostics.reconciliations == 0)
    try await observer.shutdown()
}

@Test
func sqliteObserverRetriesAMessageThatInitiallyHasNoChatJoin() async throws {
    let fixture = try MessageDatabaseFixture()
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10),
        reconciliationInterval: .seconds(30)
    )
    var iterator = observer.events().makeAsyncIterator()
    guard case .streamReady = try await iterator.next() else {
        Issue.record("Expected stream.ready as the first event.")
        return
    }

    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, is_read,
             associated_message_type)
        VALUES
            (400, 'late-chat-join-message', 'Late join', 10, 0,
             700000600000000000, 0, 0)
        """)
    try await Task.sleep(for: .milliseconds(50))
    try fixture.execute("""
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES (1, 400, 700000600000000000, 0)
        """)

    let event = try #require(try await nextEvent(of: .messageCreated, from: &iterator))
    guard case .messageCreated(let payload) = event else {
        Issue.record("Expected message.created.")
        return
    }
    #expect(payload.messageID.rawValue == "late-chat-join-message")
    #expect(observer.diagnostics.reconciliations == 0)
    try await observer.shutdown()
}

@Test
func sqliteObserverSeedsUnavailableStartupMediaWithoutAnotherDatabaseWrite() async throws {
    let fixture = try MessageDatabaseFixture()
    let attachment = fixture.attachmentDirectory.appendingPathComponent("startup-pending.jpg")
    let escaped = attachment.path.replacingOccurrences(of: "'", with: "''")
    try fixture.execute("""
        INSERT INTO attachment
            (ROWID, guid, original_guid, filename, transfer_name, mime_type, uti, total_bytes)
        VALUES
            (449, 'startup-pending-attachment', 'startup-pending-original', '\(escaped)',
             'startup-pending.jpg', 'image/jpeg', 'public.jpeg', 7);
        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (100, 449)
        """)
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10),
        reconciliationInterval: .seconds(30)
    )
    let ready = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let eventTask = Task { () throws -> RelayEvent? in
        var iterator = observer.events().makeAsyncIterator()
        guard case .streamReady = try await iterator.next() else { return nil }
        ready.continuation.yield()
        ready.continuation.finish()
        return try await nextEvent(of: .mediaAvailable, from: &iterator)
    }
    for await _ in ready.stream { break }

    try Data("startup".utf8).write(to: attachment)
    let watchdog = Task {
        try await Task.sleep(for: .seconds(3))
        try? await observer.shutdown()
    }
    let received = try await eventTask.value
    watchdog.cancel()
    let event = try #require(received)
    guard case .mediaAvailable(let payload) = event else {
        Issue.record("Expected media.available.")
        return
    }
    #expect(payload.mediaID.rawValue == "startup-pending-attachment")
    #expect(observer.diagnostics.pendingMediaChecks > 0)
    #expect(observer.diagnostics.reconciliations == 0)
    try await observer.shutdown()
}

@Test
func sqliteObserverRefreshesAnAttachmentPathMissingAtStartup() async throws {
    let fixture = try MessageDatabaseFixture()
    let attachment = fixture.attachmentDirectory.appendingPathComponent("late-path.jpg")
    try fixture.execute("""
        INSERT INTO attachment
            (ROWID, guid, original_guid, filename, transfer_name, mime_type, uti, total_bytes)
        VALUES
            (450, 'late-path-attachment', 'late-path-original', NULL,
             'late-path.jpg', 'image/jpeg', 'public.jpeg', 4);
        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (100, 450)
        """)
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10),
        reconciliationInterval: .seconds(30)
    )
    var iterator = observer.events().makeAsyncIterator()
    guard case .streamReady = try await iterator.next() else {
        Issue.record("Expected stream.ready as the first event.")
        return
    }

    try Data("late".utf8).write(to: attachment)
    let escaped = attachment.path.replacingOccurrences(of: "'", with: "''")
    try fixture.execute("UPDATE attachment SET filename = '\(escaped)' WHERE ROWID = 450")

    let event = try #require(try await nextEvent(of: .mediaAvailable, from: &iterator))
    guard case .mediaAvailable(let payload) = event else {
        Issue.record("Expected media.available.")
        return
    }
    #expect(payload.mediaID.rawValue == "late-path-attachment")
    #expect(observer.diagnostics.reconciliations == 0)
    try await observer.shutdown()
}

@Test
func sqliteObserverBoundsAndExpiresPendingMedia() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO attachment (ROWID, guid, original_guid, filename)
        VALUES
            (460, 'pending-capacity-a', 'pending-capacity-original-a', NULL),
            (461, 'pending-capacity-b', 'pending-capacity-original-b', NULL);
        INSERT INTO message_attachment_join (message_id, attachment_id)
        VALUES (100, 460), (100, 461)
        """)
    let capacityObserver = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10),
        reconciliationInterval: .seconds(30),
        pendingMediaCapacity: 1
    )
    var capacityIterator = capacityObserver.events().makeAsyncIterator()
    guard case .streamReady = try await capacityIterator.next() else {
        Issue.record("Expected stream.ready as the first event.")
        return
    }
    try await waitForCondition {
        capacityObserver.diagnostics.pendingMediaEvictions == 1
    }
    try await capacityObserver.shutdown()

    let expirationObserver = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10),
        reconciliationInterval: .seconds(30),
        pendingMediaCapacity: 10,
        pendingMediaRetention: 0
    )
    var expirationIterator = expirationObserver.events().makeAsyncIterator()
    guard case .streamReady = try await expirationIterator.next() else {
        Issue.record("Expected stream.ready as the first event.")
        return
    }
    try await waitForCondition {
        expirationObserver.diagnostics.pendingMediaExpirations == 2
    }
    try await expirationObserver.shutdown()
}

@Test
func sqliteObserverRunsPeriodicReconciliationWithoutDatabaseWrites() async throws {
    let fixture = try MessageDatabaseFixture()
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .seconds(30),
        reconciliationInterval: .milliseconds(30)
    )
    var iterator = observer.events().makeAsyncIterator()
    guard case .streamReady = try await iterator.next() else {
        Issue.record("Expected stream.ready as the first event.")
        return
    }

    try await Task.sleep(for: .milliseconds(100))
    #expect(observer.diagnostics.reconciliations >= 1)
    #expect(observer.diagnostics.incrementalBatches == 0)
    try await observer.shutdown()
}

@Test
func sqliteObserverDrainsALargeBacklogInBoundedBatches() async throws {
    let fixture = try MessageDatabaseFixture()
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10),
        reconciliationInterval: .seconds(30)
    )
    var iterator = observer.events().makeAsyncIterator()
    guard case .streamReady = try await iterator.next() else {
        Issue.record("Expected stream.ready as the first event.")
        return
    }

    let count = 600
    let messages = (0..<count).map { index in
        let rowID = 1_000 + index
        return "(\(rowID), 'backlog-\(index)', 'Backlog', 10, 0, 700001000000000000 + \(index), 0, 0)"
    }.joined(separator: ",")
    let joins = (0..<count).map { index in
        let rowID = 1_000 + index
        return "(1, \(rowID), 700001000000000000 + \(index), 0)"
    }.joined(separator: ",")
    try fixture.execute("""
        BEGIN;
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, is_read,
             associated_message_type)
        VALUES \(messages);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES \(joins);
        COMMIT;
        """)

    var received: Set<String> = []
    while received.count < count {
        let event = try #require(try await iterator.next())
        if case .messageCreated(let payload) = event,
           payload.messageID.rawValue.hasPrefix("backlog-") {
            received.insert(payload.messageID.rawValue)
        }
    }
    #expect(received.count == count)
    #expect(observer.diagnostics.incrementalBatches >= 3)
    #expect(observer.diagnostics.reconciliations == 0)
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
func sqliteIncrementalRowQueryUsesTheRowIDPlan() throws {
    let fixture = try MessageDatabaseFixture()
    let database = try SQLiteDatabase(path: fixture.path)
    let plan = try database.withStatement("""
        EXPLAIN QUERY PLAN
        SELECT ROWID
        FROM message
        WHERE ROWID > ?
        ORDER BY ROWID
        LIMIT ?
        """) { statement in
            try statement.bind(Int64(0), at: 1)
            try statement.bind(Int64(256), at: 2)
            var details: [String] = []
            while try statement.step() == .row {
                details.append(try statement.text(3))
            }
            return details
        }
    #expect(plan.contains { $0.localizedCaseInsensitiveContains("rowid>?") })
    print("SQLite incremental ROWID query plan: \(plan.joined(separator: "; "))")
}

@Test
func sqliteSnapshotLargeHistoryEvidence() async throws {
    let fixture = try MessageDatabaseFixture(seedData: false)
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
        VALUES (1, '\(MessageDatabaseFixture.oneToOneID)', '+15005550006', 'iMessage');
        BEGIN
        """)
    let rowCount = 10_000
    for start in stride(from: 0, to: rowCount, by: 500) {
        let end = min(start + 500, rowCount)
        let messages = (start..<end).map { index in
            "(\(index + 1), 'history-\(index)', 'History', NULL, 0, \(700000000000000000 + index), 0)"
        }.joined(separator: ",")
        let joins = (start..<end).map { index in
            "(1, \(index + 1), \(700000000000000000 + index), 0)"
        }.joined(separator: ",")
        try fixture.execute("""
            INSERT INTO message
                (ROWID, guid, text, handle_id, is_from_me, date, associated_message_type)
            VALUES \(messages);
            INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
            VALUES \(joins)
            """)
    }
    try fixture.execute("COMMIT")
    let store = SQLiteEventSnapshotStore(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path
    )
    let clock = ContinuousClock()
    let start = clock.now
    let result = try await store.snapshot()
    let duration = start.duration(to: clock.now)
    guard case .snapshot(let snapshot) = result else {
        Issue.record("Expected a stable large-history snapshot.")
        return
    }
    #expect(snapshot.messages.count == rowCount)
    #expect(duration < .seconds(10))
    print("SQLite 10,000-row reconciliation fixture: \(duration)")
    try await store.shutdown()
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

private func waitForCondition(
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while !condition() {
        guard clock.now < deadline else { throw EventTimeout() }
        try await clock.sleep(for: .milliseconds(10))
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
