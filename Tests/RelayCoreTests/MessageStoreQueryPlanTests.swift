import SQLite3
import Testing

@testable import RelayCore

@Test
func paginationQueryPlansBoundRepeatedWork() throws {
    let fixture = try MessageDatabaseFixture(seedData: false)
    try fixture.execute("""
        WITH RECURSIVE sequence(value) AS (
            SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 500
        )
        INSERT INTO chat (ROWID, guid, chat_identifier, service_name)
        SELECT value, 'chat-' || value, 'recipient-' || value, 'iMessage' FROM sequence;

        WITH RECURSIVE sequence(value) AS (
            SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 10000
        )
        INSERT INTO message (ROWID, guid, text, is_from_me, is_read, date)
        SELECT value, 'message-' || value, 'performance fixture', 0, 1, 700000000 + value
          FROM sequence;

        WITH RECURSIVE sequence(value) AS (
            SELECT 1 UNION ALL SELECT value + 1 FROM sequence WHERE value < 10000
        )
        INSERT INTO chat_message_join (chat_id, message_id)
        SELECT ((value - 1) % 500) + 1, value FROM sequence;
        """)
    let store = try fixture.makeSQLiteStore()

    let chatPlan = try store.connection.queryPlan(
        for: store.chatsSQL(unreadOnly: false, cursor: nil)
    ) { statement in
        sqlite3_bind_int64(statement, 1, 21)
    }
    #expect(!chatPlan.joined(separator: "\n").contains("CORRELATED SCALAR SUBQUERY"))
    #expect(chatPlan.filter { $0.contains("SCAN cj") }.count <= 1)
    #expect(chatPlan.filter { $0.contains("SCAN cm") }.count <= 1)

}
