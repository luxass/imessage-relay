import SQLite3

public final class SQLiteConversationStore: ConversationStoring, Sendable {
    private struct AggregateExpressions {
        let messageDate: String
        let filterJoin: String
        let reactionFilter: String
        let unread: String
    }

    private let executor: SQLiteExecutor

    init(executor: SQLiteExecutor) {
        self.executor = executor
    }

    public func listConversations(
        options: ConversationListOptions
    ) async throws -> PaginatedResponse<Conversation> {
        try await executor.run { database in
            try Self.list(database: database, options: options)
        }
    }

    public func conversation(id: ConversationID) async throws -> Conversation? {
        try await executor.run { database in
            guard let row = try Self.row(database: database, id: id) else { return nil }
            let participants = try Self.participants(database: database, chatRowIDs: [row.rowID])
            return try Self.map(row, participants: participants[row.rowID] ?? [])
        }
    }

    public func sendContext(id: ConversationID) async throws -> ConversationSendContext? {
        try await executor.run { database in
            guard let row = try Self.row(database: database, id: id) else { return nil }
            let participants = try Self.participants(database: database, chatRowIDs: [row.rowID])
            return ConversationSendContext(
                conversationID: id,
                providerGUID: row.guid,
                accountID: row.accountID,
                accountLogin: row.accountLogin,
                recipients: participants[row.rowID] ?? []
            )
        }
    }

    public func sendContexts(
        matchingExactParticipants expected: [RecipientHandle]
    ) async throws -> [ConversationSendContext] {
        try await executor.run { database in
            let handleRowIDs = try expected.flatMap {
                try Self.matchingHandleRowIDs(database: database, participant: $0)
            }
            guard !handleRowIDs.isEmpty else { return [] }
            let placeholders = handleRowIDs.map { _ in "?" }.joined(separator: ",")
            let chatRowIDs = try database.withStatement("""
                SELECT DISTINCT chat_id
                FROM chat_handle_join
                WHERE handle_id IN (\(placeholders))
                """) { statement in
                    for (index, rowID) in handleRowIDs.enumerated() {
                        sqlite3_bind_int64(statement, Int32(index + 1), rowID)
                    }
                    var values: [Int64] = []
                    while true {
                        switch sqlite3_step(statement) {
                        case SQLITE_ROW: values.append(sqlite3_column_int64(statement, 0))
                        case SQLITE_DONE: return values
                        default: throw SQLiteStorageError.queryFailed(database.lastError())
                        }
                    }
                }
            let participantsByChat = try Self.participants(
                database: database,
                chatRowIDs: chatRowIDs
            )
            let expectedKeys = Set(expected.map(Self.handleKey))
            let matchingRowIDs = chatRowIDs.filter {
                Set((participantsByChat[$0] ?? []).map(Self.handleKey)) == expectedKeys
            }
            return try Self.sendContexts(
                database: database,
                chatRowIDs: matchingRowIDs,
                participants: participantsByChat
            )
        }
    }

    private static func list(
        database: SQLiteDatabase,
        options: ConversationListOptions
    ) throws -> PaginatedResponse<Conversation> {
        let limit = max(1, min(options.limit, 200))
        let identity = try database.identity()
        let signature = CursorCodec.signature([
            "conversations",
            String(options.unreadOnly),
            options.participant?.type.rawValue ?? "<none>",
            options.participant?.value ?? "<none>",
        ])
        let cursor = try CursorCodec.decode(
            options.cursor,
            route: "conversations",
            databaseIdentity: identity,
            querySignature: signature
        )
        let participantHandleRowIDs = try options.participant.map {
            try matchingHandleRowIDs(database: database, participant: $0)
        }
        let rows = try conversationRows(
            database: database,
            sql: listSQL(
                schema: database.schema,
                unreadOnly: options.unreadOnly,
                cursor: cursor,
                participantHandleCount: participantHandleRowIDs?.count
            ),
            cursor: cursor,
            participantHandleRowIDs: participantHandleRowIDs ?? [],
            limit: limit
        )
        let visible = Array(rows.prefix(limit))
        let handles = try participants(database: database, chatRowIDs: visible.map(\.rowID))
        let conversations = try visible.map { try map($0, participants: handles[$0.rowID] ?? []) }
        let hasMore = rows.count > limit
        let nextCursor = try hasMore ? visible.last.map {
            try CursorCodec.encode(
                route: "conversations",
                databaseIdentity: identity,
                querySignature: signature,
                date: $0.lastDate,
                rowID: $0.rowID
            )
        } : nil
        return PaginatedResponse(items: conversations, nextCursor: nextCursor, hasMore: hasMore)
    }

    private static func conversationRows(
        database: SQLiteDatabase,
        sql: String,
        cursor: StorageCursor?,
        participantHandleRowIDs: [Int64],
        limit: Int
    ) throws -> [ConversationRow] {
        try database.withStatement(sql) { statement in
            var binding: Int32 = 1
            if let cursor {
                if let date = cursor.date {
                    date.bind(to: statement, at: binding)
                    date.bind(to: statement, at: binding + 1)
                    sqlite3_bind_int64(statement, binding + 2, cursor.rowID)
                    binding += 3
                } else {
                    sqlite3_bind_int64(statement, binding, cursor.rowID)
                    binding += 1
                }
            }
            for rowID in participantHandleRowIDs {
                sqlite3_bind_int64(statement, binding, rowID)
                binding += 1
            }
            sqlite3_bind_int64(statement, binding, Int64(limit + 1))
            var result: [ConversationRow] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: result.append(try decode(statement))
                case SQLITE_DONE: return result
                default: throw SQLiteStorageError.queryFailed(database.lastError())
                }
            }
        }
    }

    private static func listSQL(
        schema: SchemaInspector,
        unreadOnly: Bool,
        cursor: StorageCursor?,
        participantHandleCount: Int?
    ) -> String {
        let values = aggregateExpressions(schema)
        let displayName = schema.expression("display_name", table: "chat", alias: "c", fallback: "NULL")
        let roomName = schema.expression("room_name", table: "chat", alias: "c", fallback: "NULL")
        let accountID = schema.expression("account_id", table: "chat", alias: "c", fallback: "NULL")
        let accountLogin = schema.expression("account_login", table: "chat", alias: "c", fallback: "NULL")
        let cursorPredicate = if cursor == nil {
            ""
        } else if cursor?.date == nil {
            "AND ranked.last_date IS NULL AND ranked.rowid < ?"
        } else {
            """
            AND (ranked.last_date IS NULL OR ranked.last_date < ?
                 OR (ranked.last_date = ? AND ranked.rowid < ?))
            """
        }
        let participantPredicate = if let participantHandleCount {
            if participantHandleCount == 0 {
                "AND 0"
            } else {
                """
                AND EXISTS (
                    SELECT 1
                    FROM chat_handle_join filter_chj
                    WHERE filter_chj.chat_id = ranked.rowid
                      AND filter_chj.handle_id IN (
                          \(Array(repeating: "?", count: participantHandleCount).joined(separator: ","))
                      )
                )
                """
            }
        } else {
            ""
        }
        return """
            WITH aggregate_rows AS (
                SELECT cmj.chat_id,
                       MAX(NULLIF(\(values.messageDate), 0)) AS last_date,
                       \(values.unread) AS unread_count
                FROM chat_message_join cmj
                JOIN message m ON m.ROWID = cmj.message_id
                WHERE 1 = 1 \(values.filterJoin) \(values.reactionFilter)
                GROUP BY cmj.chat_id
            ), ranked AS (
                SELECT c.ROWID AS rowid, c.guid, c.chat_identifier,
                       \(displayName) AS display_name,
                       c.service_name, \(roomName) AS room_name,
                       \(accountID) AS account_id, \(accountLogin) AS account_login,
                       aggregate_rows.last_date,
                       COALESCE(aggregate_rows.unread_count, 0) AS unread_count
                FROM chat c
                LEFT JOIN aggregate_rows ON aggregate_rows.chat_id = c.ROWID
            )
            SELECT rowid, guid, chat_identifier, display_name, service_name,
                   room_name, account_id, account_login, last_date, unread_count
            FROM ranked
            WHERE 1 = 1
              \(unreadOnly ? "AND unread_count > 0" : "")
              \(cursorPredicate)
              \(participantPredicate)
            ORDER BY last_date IS NULL, last_date DESC, rowid DESC
            LIMIT ?
            """
    }

    private static func matchingHandleRowIDs(
        database: SQLiteDatabase,
        participant: RecipientHandle
    ) throws -> [Int64] {
        try database.withStatement("SELECT ROWID, id FROM handle") { statement in
            var rowIDs: [Int64] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let value = SQLiteValue.optionalText(statement, 1),
                          let stored = try? RecipientHandle.stored(value: value),
                          stored.matches(participant) else { continue }
                    rowIDs.append(sqlite3_column_int64(statement, 0))
                case SQLITE_DONE:
                    return rowIDs
                default:
                    throw SQLiteStorageError.queryFailed(database.lastError())
                }
            }
        }
    }

    private static func sendContexts(
        database: SQLiteDatabase,
        chatRowIDs: [Int64],
        participants: [Int64: [RecipientHandle]]
    ) throws -> [ConversationSendContext] {
        guard !chatRowIDs.isEmpty else { return [] }
        let accountID = database.schema.expression(
            "account_id", table: "chat", alias: "c", fallback: "NULL"
        )
        let accountLogin = database.schema.expression(
            "account_login", table: "chat", alias: "c", fallback: "NULL"
        )
        let placeholders = chatRowIDs.map { _ in "?" }.joined(separator: ",")
        return try database.withStatement("""
            SELECT c.ROWID, c.guid, \(accountID), \(accountLogin)
            FROM chat c
            WHERE c.ROWID IN (\(placeholders))
            ORDER BY c.ROWID
            """) { statement in
                for (index, rowID) in chatRowIDs.enumerated() {
                    sqlite3_bind_int64(statement, Int32(index + 1), rowID)
                }
                var values: [ConversationSendContext] = []
                while true {
                    switch sqlite3_step(statement) {
                    case SQLITE_ROW:
                        let rowID = sqlite3_column_int64(statement, 0)
                        let guid = try SQLiteValue.text(statement, 1)
                        values.append(ConversationSendContext(
                            conversationID: try ConversationID(validating: guid),
                            providerGUID: guid,
                            accountID: SQLiteValue.optionalText(statement, 2),
                            accountLogin: SQLiteValue.optionalText(statement, 3),
                            recipients: participants[rowID] ?? []
                        ))
                    case SQLITE_DONE: return values
                    default: throw SQLiteStorageError.queryFailed(database.lastError())
                    }
                }
            }
    }

    private static func handleKey(_ handle: RecipientHandle) -> String {
        "\(handle.type.rawValue)\u{0}\(handle.value)"
    }

    private static func row(database: SQLiteDatabase, id: ConversationID) throws -> ConversationRow? {
        let schema = database.schema
        let displayName = schema.expression("display_name", table: "chat", alias: "c", fallback: "NULL")
        let roomName = schema.expression("room_name", table: "chat", alias: "c", fallback: "NULL")
        let accountID = schema.expression("account_id", table: "chat", alias: "c", fallback: "NULL")
        let accountLogin = schema.expression("account_login", table: "chat", alias: "c", fallback: "NULL")
        let values = aggregateExpressions(schema)
        return try database.withStatement("""
            SELECT c.ROWID, c.guid, c.chat_identifier, \(displayName), c.service_name,
                   \(roomName), \(accountID), \(accountLogin),
                   MAX(NULLIF(\(values.messageDate), 0)), COALESCE(\(values.unread), 0)
            FROM chat c
            LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID \(values.filterJoin)
            LEFT JOIN message m ON m.ROWID = cmj.message_id \(values.reactionFilter)
            WHERE c.guid = ?
            GROUP BY c.ROWID
            """) { statement -> ConversationRow? in
                sqlite3_bind_text(statement, 1, id.rawValue, -1, sqliteTransient)
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    return try decode(statement)
                case SQLITE_DONE:
                    return nil
                default:
                    throw SQLiteStorageError.queryFailed(database.lastError())
                }
            }
    }

    private static func aggregateExpressions(_ schema: SchemaInspector) -> AggregateExpressions {
        let date = schema.expression(
            "message_date",
            table: "chat_message_join",
            alias: "cmj",
            fallback: "m.date"
        )
        let filter = schema.hasColumn("filter_action", in: "chat_message_join")
            ? "AND cmj.filter_action = 0" : ""
        let reactions = schema.hasColumn("associated_message_type", in: "message")
            ? """
            AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 2000 AND 2006)
            AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 3000 AND 3006)
            """
            : ""
        let unreadColumns = ["is_read", "is_from_me", "item_type", "is_finished", "is_system_message"]
        let unread = unreadColumns.allSatisfy { schema.hasColumn($0, in: "message") }
            ? """
            SUM(CASE WHEN m.is_read = 0 AND m.is_from_me = 0 AND m.item_type = 0
                     AND m.is_finished = 1 AND m.is_system_message = 0 THEN 1 ELSE 0 END)
            """
            : "0"
        return AggregateExpressions(
            messageDate: date,
            filterJoin: filter,
            reactionFilter: reactions,
            unread: unread
        )
    }

    private static func decode(_ statement: OpaquePointer) throws -> ConversationRow {
        ConversationRow(
            rowID: sqlite3_column_int64(statement, 0),
            guid: try SQLiteValue.text(statement, 1),
            identifier: SQLiteValue.optionalText(statement, 2),
            displayName: SQLiteValue.optionalText(statement, 3),
            service: SQLiteValue.optionalText(statement, 4),
            roomName: SQLiteValue.optionalText(statement, 5),
            accountID: SQLiteValue.optionalText(statement, 6),
            accountLogin: SQLiteValue.optionalText(statement, 7),
            lastDate: SQLiteNumber.read(statement, 8),
            unreadCount: Int(sqlite3_column_int64(statement, 9))
        )
    }

    private static func map(
        _ row: ConversationRow,
        participants: [RecipientHandle]
    ) throws -> Conversation {
        Conversation(
            id: try ConversationID(validating: row.guid),
            providerGUID: row.guid,
            identifier: row.identifier,
            displayName: row.displayName,
            service: row.service,
            isGroup: participants.count > 1 || row.roomName != nil || row.guid.contains(";+;"),
            participants: participants,
            unreadCount: row.unreadCount,
            lastMessageAt: SQLiteRows.timestamp(row.lastDate)
        )
    }

    private static func participants(
        database: SQLiteDatabase,
        chatRowIDs: [Int64]
    ) throws -> [Int64: [RecipientHandle]] {
        guard !chatRowIDs.isEmpty else { return [:] }
        let original = database.schema.expression(
            "uncanonicalized_id",
            table: "handle",
            alias: "h",
            fallback: "NULL"
        )
        let placeholders = chatRowIDs.map { _ in "?" }.joined(separator: ",")
        return try database.withStatement("""
            SELECT chj.chat_id, h.id, \(original)
            FROM chat_handle_join chj
            JOIN handle h ON h.ROWID = chj.handle_id
            WHERE chj.chat_id IN (\(placeholders))
            ORDER BY chj.chat_id, h.ROWID
            """) { statement in
                for (index, id) in chatRowIDs.enumerated() {
                    sqlite3_bind_int64(statement, Int32(index + 1), id)
                }
                var result: [Int64: [RecipientHandle]] = [:]
                while sqlite3_step(statement) == SQLITE_ROW {
                    let chatID = sqlite3_column_int64(statement, 0)
                    if let value = SQLiteValue.optionalText(statement, 1),
                       let handle = try? RecipientHandle.stored(
                        value: value,
                        originalValue: SQLiteValue.optionalText(statement, 2)
                       ) {
                        result[chatID, default: []].append(handle)
                    }
                }
                return result
            }
    }
}
