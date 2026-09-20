import Foundation
import Testing

@testable import RelayCore

@Test
func sqliteTimestampStreamSeeksNearItsWatermark() throws {
    let fixture = try MessageDatabaseFixture(seedData: false)
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
        VALUES (1, 'seek-chat', 'person', 'iMessage');
        CREATE INDEX message_date_read_seek_test ON message(date_read);
        CREATE INDEX chat_message_join_message_seek_test ON chat_message_join(message_id);
        WITH RECURSIVE rows(value) AS (
            VALUES(1)
            UNION ALL
            SELECT value + 1 FROM rows WHERE value < 100000
        )
        INSERT INTO message
            (ROWID, guid, text, is_from_me, date, is_read, date_read,
             date_delivered, associated_message_type)
        SELECT value, 'seek-' || value, 'History', 0, value, 1, value, 0, 0
        FROM rows;
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        SELECT 1, ROWID, date, 0 FROM message;
        """)
    let database = try SQLiteDatabase(path: fixture.path)
    let positions = SQLiteEventSnapshotStore.IncrementalPositions(
        messageRowID: 100_000,
        attachmentJoinRowID: 0,
        read: .init(value: .integer(99_999), rowID: 99_999),
        delivery: .init(value: .integer(100_000), rowID: 100_000),
        targetedRowID: 0
    )

    let batch = try SQLiteEventSnapshotStore.incrementalBatch(
        database: database,
        positions: positions,
        limit: 256
    )

    #expect(batch.readUpdates.map(\.messageID.rawValue) == ["seek-100000"])
    #expect(batch.readMetrics.fullScanSteps < 100)
    #expect(batch.readMetrics.virtualMachineSteps < 5_000)

    let empty = try SQLiteEventSnapshotStore.incrementalBatch(
        database: database,
        positions: batch.positions,
        limit: 256
    )
    #expect(empty.readUpdates.isEmpty)
    #expect(empty.readMetrics.fullScanSteps < 100)
    #expect(empty.readMetrics.virtualMachineSteps < 5_000)
}

@Test
func sqliteTargetedRechecksContinueAcrossFallbackTicks() async throws {
    let fixture = try MessageDatabaseFixture(seedData: false)
    try seedObservedHistory(fixture, count: 600)
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10),
        reconciliationInterval: .seconds(60)
    )
    let ready = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let eventTask = Task { () throws -> RelayEvent? in
        var iterator = observer.events().makeAsyncIterator()
        guard case .streamReady = try await iterator.next() else { return nil }
        ready.continuation.yield()
        ready.continuation.finish()
        return try await nextRegressionEvent(of: .messageUpdated, from: &iterator)
    }
    for await _ in ready.stream { break }

    try fixture.execute("UPDATE message SET is_read = 1 WHERE ROWID = 600")
    let event = try await regressionValue(of: eventTask, timeout: .seconds(3))

    guard case .messageUpdated(let payload) = event else {
        Issue.record("Expected a message.updated event.")
        return
    }
    #expect(payload.messageID.rawValue == "history-600")
    #expect(observer.diagnostics.targetedRows >= 600)
    #expect(observer.diagnostics.reconciliations == 0)
    try await observer.shutdown()
}

@Test
func sqliteIncrementalStreamsAdvancePastUnmappedCandidates() throws {
    let fixture = try MessageDatabaseFixture(seedData: false)
    try seedObservedHistory(fixture, count: 4)
    try fixture.execute("""
        CREATE INDEX message_date_read_orphan_test ON message(date_read);
        DELETE FROM chat_message_join WHERE message_id IN (1, 2);
        UPDATE message SET is_read = 1, date_read = 100 WHERE ROWID IN (1, 2, 3);
        """)
    let database = try SQLiteDatabase(path: fixture.path)
    var positions = SQLiteEventSnapshotStore.IncrementalPositions(
        messageRowID: 4,
        attachmentJoinRowID: 0,
        read: .init(value: .integer(0), rowID: 4),
        delivery: .init(value: .integer(0), rowID: 4),
        targetedRowID: 0
    )

    let first = try SQLiteEventSnapshotStore.incrementalBatch(
        database: database,
        positions: positions,
        limit: 2
    )
    #expect(first.readUpdates.isEmpty)
    #expect(first.positions.read.value == .integer(100))
    #expect(first.positions.read.rowID == 2)
    #expect(first.hasMore)

    positions = first.positions
    let second = try SQLiteEventSnapshotStore.incrementalBatch(
        database: database,
        positions: positions,
        limit: 2
    )
    #expect(second.readUpdates.map(\.messageID.rawValue) == ["history-3"])
    #expect(second.positions.read.rowID == 3)

    let firstTargeted = try SQLiteEventSnapshotStore.targetedStateChanges(
        database: database,
        after: 0,
        limit: 2
    )
    #expect(firstTargeted.candidates.map(\.rowID) == [1, 2])
    #expect(firstTargeted.nextRowID == 2)
    let secondTargeted = try SQLiteEventSnapshotStore.targetedStateChanges(
        database: database,
        after: firstTargeted.nextRowID,
        limit: 2
    )
    #expect(secondTargeted.candidates.compactMap(\.message?.messageID.rawValue) == [
        "history-3", "history-4"
    ])
}

@Test
func sqliteObserverReadsRejectPositionsFromAnotherGeneration() async throws {
    let original = try MessageDatabaseFixture(seedData: false)
    let replacement = try MessageDatabaseFixture(seedData: false)
    try seedObservedHistory(original, count: 1)
    try seedObservedHistory(replacement, count: 2)
    let store = SQLiteEventSnapshotStore(
        path: original.path,
        attachmentDirectory: original.attachmentDirectory.path
    )
    guard case .snapshot(let snapshot) = try await store.snapshot() else {
        Issue.record("Expected the original snapshot.")
        return
    }

    try FileManager.default.removeItem(atPath: original.path)
    try FileManager.default.moveItem(atPath: replacement.path, toPath: original.path)

    let incremental = try await store.incrementalBatch(
        positions: snapshot.positions,
        limit: 256,
        expectedFileIdentity: snapshot.fileIdentity
    )
    guard case .databaseChanged = incremental else {
        Issue.record("Expected the old-generation incremental read to be rejected.")
        return
    }
    let reconciliation = try await store.snapshot(expectedFileIdentity: snapshot.fileIdentity)
    guard case .databaseChanged = reconciliation else {
        Issue.record("Expected the old-generation reconciliation to be rejected.")
        return
    }
    try await store.shutdown()
}

@Test
func sqliteReconciliationRecoversMediaEvictedBeforeItsFileAppears() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO attachment (ROWID, guid, original_guid, filename)
        VALUES (470, 'blocking-media', 'blocking-media-original', NULL);
        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (100, 470)
        """)
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path,
        attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10),
        reconciliationInterval: .milliseconds(100),
        pendingMediaCapacity: 1
    )
    let ready = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    let eventTask = Task { () throws -> RelayEvent? in
        var iterator = observer.events().makeAsyncIterator()
        guard case .streamReady = try await iterator.next() else { return nil }
        ready.continuation.yield()
        ready.continuation.finish()
        return try await nextRegressionEvent(of: .mediaAvailable, from: &iterator)
    }
    for await _ in ready.stream { break }

    let available = fixture.attachmentDirectory.appendingPathComponent("evicted-available.jpg")
    let escaped = available.path.replacingOccurrences(of: "'", with: "''")
    try fixture.execute("""
        INSERT INTO attachment (ROWID, guid, original_guid, filename)
        VALUES (471, 'evicted-available', 'evicted-available-original', '\(escaped)');
        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (100, 471)
        """)
    try await waitForRegressionCondition {
        observer.diagnostics.pendingMediaEvictions > 0
    }
    try Data("available".utf8).write(to: available)

    let event = try await regressionValue(of: eventTask, timeout: .seconds(3))
    guard case .mediaAvailable(let payload) = event else {
        Issue.record("Expected media.available after reconciliation.")
        return
    }
    #expect(payload.mediaID.rawValue == "evicted-available")
    #expect(observer.diagnostics.reconciliations > 0)
    try await observer.shutdown()
}

private func seedObservedHistory(_ fixture: MessageDatabaseFixture, count: Int) throws {
    try fixture.execute("""
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
        VALUES (1, 'history-chat', 'person', 'iMessage');
        BEGIN
        """)
    for start in stride(from: 1, through: count, by: 250) {
        let end = min(start + 249, count)
        let messages = (start...end).map { rowID in
            "(\(rowID), 'history-\(rowID)', 'History', 0, \(rowID), 0, 0, 0, 0)"
        }.joined(separator: ",")
        let joins = (start...end).map { rowID in
            "(1, \(rowID), \(rowID), 0)"
        }.joined(separator: ",")
        try fixture.execute("""
            INSERT INTO message
                (ROWID, guid, text, is_from_me, date, is_read, date_read,
                 date_delivered, associated_message_type)
            VALUES \(messages);
            INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
            VALUES \(joins)
            """)
    }
    try fixture.execute("COMMIT")
}

private func nextRegressionEvent(
    of type: RelayEventType,
    from iterator: inout AsyncThrowingStream<RelayEvent, any Error>.Iterator
) async throws -> RelayEvent? {
    while let event = try await iterator.next() {
        if event.type == type { return event }
    }
    return nil
}

private struct RegressionTimeout: Error {}

private func regressionValue<Value: Sendable>(
    of task: Task<Value, any Error>,
    timeout: Duration
) async throws -> Value {
    defer { task.cancel() }
    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await task.value }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RegressionTimeout()
        }
        guard let result = try await group.next() else { throw RegressionTimeout() }
        group.cancelAll()
        return result
    }
}

private func waitForRegressionCondition(
    _ condition: @escaping @Sendable () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while !condition() {
        guard clock.now < deadline else { throw RegressionTimeout() }
        try await clock.sleep(for: .milliseconds(10))
    }
}
