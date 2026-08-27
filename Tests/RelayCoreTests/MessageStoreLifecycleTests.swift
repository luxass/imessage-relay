import Testing

@testable import RelayCore

@Test
func concurrentAndRepeatedShutdownSharesCleanup() async throws {
    let fixture = try MessageDatabaseFixture()
    let store = fixture.makeStore()
    _ = await store.status()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<16 {
            group.addTask { try await store.shutdown() }
        }
        try await group.waitForAll()
    }
    try await store.shutdown()
    try await store.shutdown()

    await #expect(throws: MessageStore.StoreError.self) {
        try await store.chats()
    }
    await #expect(throws: MessageStore.StoreError.self) {
        try await store.attachmentResource(rowid: 1)
    }
}
