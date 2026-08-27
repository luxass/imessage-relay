import Foundation
import Testing

@testable import RelayCore

@Test
func statusReportsReadyDatabaseAndFingerprint() async throws {
    let fixture = try MessageDatabaseFixture()
    let status = await fixture.makeStore().status()

    #expect(status.ready)
    #expect(status.error == nil)
    #expect(status.fingerprint.hasPrefix("v3:device="))
}

@Test
func fingerprintSurvivesDatabaseMutation() async throws {
    let fixture = try MessageDatabaseFixture()
    let store = fixture.makeStore()
    let fingerprint = await store.status().fingerprint

    try fixture.execute("INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 999)")

    #expect(await store.status().fingerprint == fingerprint)
}

@Test
func fingerprintChangesWhenDatabaseFileIsReplaced() async throws {
    let fixture = try MessageDatabaseFixture()
    let replacement = try MessageDatabaseFixture()
    let fingerprint = await fixture.makeStore().status().fingerprint

    try FileManager.default.removeItem(atPath: fixture.path)
    try FileManager.default.copyItem(atPath: replacement.path, toPath: fixture.path)

    #expect(await fixture.makeStore().status().fingerprint != fingerprint)
}

@Test
func fingerprintChangesWhenDatabaseIsOverwrittenInPlace() async throws {
    let fixture = try MessageDatabaseFixture()
    let replacement = try MessageDatabaseFixture()
    try replacement.execute("UPDATE chat SET guid = 'replacement-anchor' WHERE ROWID = 1")
    let fingerprint = await fixture.makeStore().status().fingerprint
    let inode = try #require(
        FileManager.default.attributesOfItem(atPath: fixture.path)[.systemFileNumber] as? NSNumber
    )

    try Data(contentsOf: URL(fileURLWithPath: replacement.path))
        .write(to: URL(fileURLWithPath: fixture.path), options: [])

    let overwrittenInode = try #require(
        FileManager.default.attributesOfItem(atPath: fixture.path)[.systemFileNumber] as? NSNumber
    )
    #expect(overwrittenInode == inode)
    #expect(await fixture.makeStore().status().fingerprint != fingerprint)
}

@Test
func redactedDatabaseStatusEncodingCanBeDecoded() throws {
    let status = DatabaseStatus(
        ready: false,
        path: "/private/chat.db",
        fingerprint: "fingerprint",
        error: "private failure"
    )

    let decoded = try JSONDecoder().decode(DatabaseStatus.self, from: JSONEncoder().encode(status))
    #expect(!decoded.ready)
    #expect(decoded.path.isEmpty)
    #expect(decoded.fingerprint == status.fingerprint)
    #expect(decoded.error == nil)
}
