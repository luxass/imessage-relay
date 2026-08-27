import SQLite3

extension SQLiteMessageStore {
    private typealias ChatRow = (Int64, String, String, String, String, PageDate?, Int)

    func chats(
        limit: Int = 20,
        unreadOnly: Bool = false,
        cursor encodedCursor: String? = nil
    ) throws -> Page<Chat> {
        let signature = unreadOnly ? "unread" : "all"
        let cursor = try decodePageCursor(encodedCursor, kind: "chats", signature: signature)
        let sql = chatsSQL(unreadOnly: unreadOnly, cursor: cursor)
        let visibleLimit = Self.clampLimit(limit)

        let rows: [ChatRow] =
            try connection.withStatement(sql) { statement in
                var binding: Int32 = 1
                if let cursor {
                    if let date = cursor.date {
                        date.bind(to: statement, at: binding)
                        date.bind(to: statement, at: binding + 1)
                        sqlite3_bind_int64(statement, binding + 2, cursor.rowid)
                        binding += 3
                    } else {
                        sqlite3_bind_int64(statement, binding, cursor.rowid)
                        binding += 1
                    }
                }
                sqlite3_bind_int64(statement, binding, Int64(visibleLimit + 1))
                var rows: [(Int64, String, String, String, String, PageDate?, Int)] = []
                while true {
                    switch sqlite3_step(statement) {
                    case SQLITE_ROW:
                        let date = PageDate.read(from: statement, at: 5)
                        rows.append((
                            sqlite3_column_int64(statement, 0),
                            Self.text(statement, 1),
                            Self.text(statement, 2),
                            Self.text(statement, 3),
                            Self.text(statement, 4),
                            date,
                            Int(sqlite3_column_int64(statement, 6))
                        ))
                    case SQLITE_DONE:
                        return rows
                    default:
                        throw StoreError.queryFailed(connection.lastError())
                    }
                }
            }

        let visibleRows = Array(rows.prefix(visibleLimit))
        let participants = try participants(forChatIDs: visibleRows.map(\.0))
        let chats = visibleRows.map { decodeChat($0, participants: participants[$0.0] ?? []) }
        let hasMore = rows.count > visibleLimit
        let nextCursor = try hasMore ? visibleRows.last.map {
            try encodePageCursor(
                kind: "chats",
                signature: signature,
                date: $0.5,
                rowid: $0.0
            )
        } : nil
        return Page(items: chats, nextCursor: nextCursor, hasMore: hasMore)
    }

    func chat(id: Int64) throws -> Chat? {
        let identifier = schema.expression("chat_identifier", in: "chat", alias: "c", fallback: "''")
        let guid = schema.expression("guid", in: "chat", alias: "c", fallback: "''")
        let displayName = schema.expression("display_name", in: "chat", alias: "c", fallback: "''")
        let service = schema.expression("service_name", in: "chat", alias: "c", fallback: "''")
        let messageDate = schema.expression("date", in: "message", alias: "m", fallback: "NULL")
        let unread = schema.hasColumn("is_from_me", in: "message")
            && schema.hasColumn("is_read", in: "message")
            ? "SUM(CASE WHEN m.is_from_me = 0 AND m.is_read = 0 THEN 1 ELSE 0 END)"
            : "0"
        let row: ChatRow? = try connection.withStatement("""
            SELECT c.ROWID,
                   COALESCE(\(identifier), ''),
                   COALESCE(\(guid), ''),
                   COALESCE(\(displayName), ''),
                   COALESCE(\(service), ''),
                   MAX(\(messageDate)),
                   COALESCE(\(unread), 0)
              FROM chat c
              LEFT JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
              LEFT JOIN message m ON m.ROWID = cmj.message_id
             WHERE c.ROWID = ?
             GROUP BY c.ROWID
            """) { statement in
            sqlite3_bind_int64(statement, 1, id)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return (
                    sqlite3_column_int64(statement, 0),
                    Self.text(statement, 1),
                    Self.text(statement, 2),
                    Self.text(statement, 3),
                    Self.text(statement, 4),
                    PageDate.read(from: statement, at: 5),
                    Int(sqlite3_column_int64(statement, 6))
                )
            case SQLITE_DONE:
                return nil
            default:
                throw StoreError.queryFailed(connection.lastError())
            }
        }
        guard let row else { return nil }
        let participants = try participants(forChatIDs: [id])[id] ?? []
        return decodeChat(row, participants: participants)
    }

    private func decodeChat(_ row: ChatRow, participants: [String]) -> Chat {
        let displayName = row.3.isEmpty ? nil : row.3
        return Chat(
            id: row.0,
            guid: row.2,
            identifier: row.1,
            name: displayName ?? row.1,
            displayName: displayName,
            service: row.4,
            isGroup: row.2.contains(";+;") || row.1.contains(";+;"),
            participants: participants,
            lastMessageAt: Self.dateText(row.5?.doubleValue),
            unreadCount: row.6
        )
    }

    func chatsSQL(unreadOnly: Bool, cursor: PageCursor?) -> String {
        let identifier = schema.expression("chat_identifier", in: "chat", alias: "c", fallback: "''")
        let guid = schema.expression("guid", in: "chat", alias: "c", fallback: "''")
        let displayName = schema.expression("display_name", in: "chat", alias: "c", fallback: "''")
        let service = schema.expression("service_name", in: "chat", alias: "c", fallback: "''")
        let messageDate = schema.expression("date", in: "message", alias: "cm", fallback: "NULL")
        let unread = schema.hasColumn("is_from_me", in: "message")
            && schema.hasColumn("is_read", in: "message")
            ? "SUM(CASE WHEN cm.is_from_me = 0 AND cm.is_read = 0 THEN 1 ELSE 0 END)"
            : "0"
        var cursorPredicate = ""
        if let cursor {
            cursorPredicate = cursor.date == nil
                ? "AND ranked.last_date IS NULL AND ranked.rowid < ?"
                : """
                  AND (ranked.last_date IS NULL
                       OR ranked.last_date < ?
                       OR (ranked.last_date = ? AND ranked.rowid < ?))
                  """
        }
        return """
            -- A stateless cursor cannot bound this aggregate: last_date and unread are
            -- derived from all messages in each chat. Keep it as one shared pass rather
            -- than repeating correlated aggregates for every candidate chat.
            WITH aggregates AS (
                SELECT cj.chat_id,
                       MAX(\(messageDate)) AS last_date,
                       \(unread) AS unread
                  FROM chat_message_join cj
                  JOIN message cm ON cm.ROWID = cj.message_id
                 GROUP BY cj.chat_id
            ), ranked AS (
                SELECT c.ROWID AS rowid,
                       COALESCE(\(identifier), '') AS identifier,
                       COALESCE(\(guid), '') AS guid,
                       COALESCE(\(displayName), '') AS display_name,
                       COALESCE(\(service), '') AS service,
                       aggregates.last_date,
                       COALESCE(aggregates.unread, 0) AS unread
                  FROM chat c
                  LEFT JOIN aggregates ON aggregates.chat_id = c.ROWID
            )
            SELECT ranked.rowid, ranked.identifier, ranked.guid, ranked.display_name,
                   ranked.service, ranked.last_date, ranked.unread
              FROM ranked
             WHERE 1 = 1
               \(unreadOnly ? "AND ranked.unread > 0" : "")
               \(cursorPredicate)
             ORDER BY ranked.last_date IS NULL, ranked.last_date DESC, ranked.rowid DESC
             LIMIT ?
            """
    }

    func sendTarget(chatID: Int64) throws -> ChatSendTarget? {
        let guidColumn = schema.expression("guid", in: "chat", alias: "c", fallback: "''")
        let identifierColumn = schema.expression("chat_identifier", in: "chat", alias: "c", fallback: "''")
        let chat: (guid: String, identifier: String)? = try connection.withStatement("""
            SELECT COALESCE(\(guidColumn), ''), COALESCE(\(identifierColumn), '')
              FROM chat c
             WHERE c.ROWID = ?
            """) { statement in
            sqlite3_bind_int64(statement, 1, chatID)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return (Self.text(statement, 0), Self.text(statement, 1))
            case SQLITE_DONE:
                return nil
            default:
                throw StoreError.queryFailed(connection.lastError())
            }
        }
        guard let chat else { return nil }
        guard !chat.guid.isEmpty else {
            throw StoreError.queryFailed("chat \(chatID) has no GUID and cannot be targeted")
        }

        var recipients = try participants(forChatIDs: [chatID])[chatID] ?? []
        let isGroup = chat.guid.contains(";+;") || chat.identifier.contains(";+;")
        if recipients.isEmpty, !isGroup, !chat.identifier.isEmpty {
            recipients = [chat.identifier]
        }
        var seen: Set<String> = []
        recipients = recipients.filter { !$0.isEmpty && seen.insert($0).inserted }
        return ChatSendTarget(chatGuid: chat.guid, recipients: recipients)
    }

    private func participants(forChatIDs ids: [Int64]) throws -> [Int64: [String]] {
        guard !ids.isEmpty,
              schema.hasTable("chat_handle_join"),
              schema.hasTable("handle"),
              schema.hasColumn("id", in: "handle") else {
            return [:]
        }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT chj.chat_id, h.id
              FROM chat_handle_join chj
              JOIN handle h ON h.ROWID = chj.handle_id
             WHERE chj.chat_id IN (\(placeholders))
             ORDER BY chj.chat_id, h.ROWID
            """
        return try connection.withStatement(sql) { statement in
            for (index, id) in ids.enumerated() {
                sqlite3_bind_int64(statement, Int32(index + 1), id)
            }
            var result: [Int64: [String]] = [:]
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    result[sqlite3_column_int64(statement, 0), default: []]
                        .append(Self.text(statement, 1))
                case SQLITE_DONE:
                    return result
                default:
                    throw StoreError.queryFailed(connection.lastError())
                }
            }
        }
    }
}
