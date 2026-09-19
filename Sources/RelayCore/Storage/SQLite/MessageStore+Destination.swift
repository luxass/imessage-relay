import SQLite3

extension SQLiteMessageStore {
    static func destinationMatches(
        database: SQLiteDatabase,
        message: Message,
        destination: MessageDestination,
        accountID: String?
    ) throws -> Bool {
        if let accountID,
           database.schema.hasColumn("account_id", in: "chat"),
           !(try conversation(
            database: database,
            id: message.conversationID,
            usesAccount: accountID
           )) {
            return false
        }
        switch destination {
        case .conversation(let conversationID):
            return message.conversationID == conversationID
        case .recipient(let recipient):
            return try handles(
                database: database,
                conversationID: message.conversationID
            ).contains { $0.matches(recipient) }
        case .participants(let participants):
            let stored = try handles(
                database: database,
                conversationID: message.conversationID
            )
            return Set(stored.map(handleKey)) == Set(participants.map(handleKey))
        }
    }

    private static func handles(
        database: SQLiteDatabase,
        conversationID: ConversationID
    ) throws -> [RecipientHandle] {
        let original = database.schema.expression(
            "uncanonicalized_id", table: "handle", alias: "h", fallback: "NULL"
        )
        return try database.withStatement("""
            SELECT h.id, \(original)
            FROM chat c
            JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE c.guid = ?
            """) { statement in
                sqlite3_bind_text(statement, 1, conversationID.rawValue, -1, sqliteTransient)
                var values: [RecipientHandle] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let handle = try? RecipientHandle.stored(
                        value: SQLiteValue.text(statement, 0),
                        originalValue: SQLiteValue.optionalText(statement, 1)
                    ) {
                        values.append(handle)
                    }
                }
                return values
            }
    }

    private static func handleKey(_ handle: RecipientHandle) -> String {
        "\(handle.type.rawValue)\u{0}\(handle.value)"
    }

    private static func conversation(
        database: SQLiteDatabase,
        id: ConversationID,
        usesAccount accountID: String
    ) throws -> Bool {
        try database.withStatement("""
            SELECT 1
            FROM chat
            WHERE guid = ? AND account_id = ?
            LIMIT 1
            """) { statement in
                sqlite3_bind_text(statement, 1, id.rawValue, -1, sqliteTransient)
                sqlite3_bind_text(statement, 2, accountID, -1, sqliteTransient)
                return sqlite3_step(statement) == SQLITE_ROW
            }
    }
}
