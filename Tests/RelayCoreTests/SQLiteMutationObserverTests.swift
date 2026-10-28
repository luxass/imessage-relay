import Foundation
import Testing

@testable import RelayCore

@Test(.timeLimit(.minutes(1)))
func observerFindsBackdatedAndEqualMutationStampsOnOldRows() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        PRAGMA journal_mode=WAL;
        ALTER TABLE message ADD COLUMN date_edited INTEGER;
        ALTER TABLE message ADD COLUMN date_retracted INTEGER;
        UPDATE message SET date_edited = 800000000000000000 WHERE ROWID = 100;
        """)
    let observer = SQLiteMessageChangeObserver(
        path: fixture.path, attachmentDirectory: fixture.attachmentDirectory.path,
        pollInterval: .milliseconds(10), reconciliationInterval: .seconds(30)
    )
    var iterator = observer.events().makeAsyncIterator()
    #expect(try await iterator.next()?.type == .streamReady)
    try fixture.execute("""
        UPDATE message SET date_edited = 700000000000000001 WHERE ROWID IN (100, 101);
        UPDATE message SET date_retracted = 700000000000000001 WHERE ROWID = 102;
        """)
    var changes: [String: [MessageChangedField]] = [:]
    while changes.count < 3 {
        if case .messageUpdated(let payload) = try await iterator.next() {
            #expect(changes[payload.messageID.rawValue] == nil)
            changes[payload.messageID.rawValue] = payload.changedFields
        }
    }
    #expect(changes[MessageDatabaseFixture.rootMessageID] == [.editedAt, .text, .parts])
    #expect(changes["00000000-0000-0000-0000-000000000101"] == [.editedAt, .text, .parts])
    #expect(changes["00000000-0000-0000-0000-000000000102"] == [.unsentAt, .text, .parts, .attachments])
    // Preserve exact integer stamps even when two values round to the same Date.
    try fixture.execute("UPDATE message SET date_edited = 700000000000000002 WHERE ROWID = 100;")
    if case .messageUpdated(let payload) = try await iterator.next() {
        #expect(payload.messageID.rawValue == MessageDatabaseFixture.rootMessageID)
        #expect(payload.changedFields == [.editedAt, .text, .parts])
    } else {
        Issue.record("Expected the subsequent edit, not a duplicate or creation event.")
    }
    #expect(observer.diagnostics.reconciliations == 0)
    try await observer.shutdown()
}

@Test
func fullAndTargetedSnapshotsUseTheSameMutationState() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        PRAGMA journal_mode=WAL;
        ALTER TABLE message ADD COLUMN date_edited INTEGER;
        ALTER TABLE message ADD COLUMN date_retracted INTEGER;
        """)
    let store = SQLiteEventSnapshotStore(path: fixture.path, attachmentDirectory: fixture.attachmentDirectory.path)
    guard case .snapshot(let before) = try await store.snapshot() else {
        Issue.record("Expected a baseline snapshot."); return
    }
    try fixture.execute("UPDATE message SET date_retracted = 123 WHERE ROWID = 100;")
    guard case .snapshot(let after) = try await store.snapshot() else {
        Issue.record("Expected an updated snapshot."); return
    }
    let events = SQLiteEventSnapshotStore.events(
        from: before, to: after, newlyAvailableMedia: [], observedAt: Timestamp(Date())
    )
    #expect(events.count == 1)
    guard case .messageUpdated(let event) = events.first else {
        Issue.record("Expected an unsend update."); return
    }
    #expect(event.changedFields == [.unsentAt, .text, .parts, .attachments])
    guard case .value(let batch) = try await store.targetedBatch(
        after: 0, limit: 1, expectedFileIdentity: after.fileIdentity
    ) else {
        Issue.record("Expected a targeted batch."); return
    }
    #expect(batch.candidates.first?.message == after.messages[event.messageID])
    try await store.shutdown()
}
