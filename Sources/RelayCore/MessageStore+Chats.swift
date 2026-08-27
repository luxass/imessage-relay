import SQLite3

extension MessageStore {
    public func chats(limit: Int = 20, unreadOnly: Bool = false) throws -> [Chat] {
        let identifier = schema.expression("chat_identifier", in: "chat", alias: "c", fallback: "''")
        let guid = schema.expression("guid", in: "chat", alias: "c", fallback: "''")
        let displayName = schema.expression("display_name", in: "chat", alias: "c", fallback: "''")
        let service = schema.expression("service_name", in: "chat", alias: "c", fallback: "''")
        let messageDate = schema.expression("date", in: "message", alias: "cm", fallback: "NULL")
        let unread: String
        if schema.hasColumn("is_from_me", in: "message"), schema.hasColumn("is_read", in: "message") {
            unread = """
                (SELECT COUNT(*)
                   FROM chat_message_join cj
                   JOIN message cm ON cm.ROWID = cj.message_id
                  WHERE cj.chat_id = c.ROWID
                    AND cm.is_from_me = 0 AND cm.is_read = 0)
                """
        } else {
            unread = "0"
        }

        let sql = """
            SELECT sub.rowid, sub.identifier, sub.guid, sub.display_name,
                   sub.service, sub.last_date, sub.unread
              FROM (
                    SELECT c.ROWID AS rowid,
                           COALESCE(\(identifier), '') AS identifier,
                           COALESCE(\(guid), '') AS guid,
                           COALESCE(\(displayName), '') AS display_name,
                           COALESCE(\(service), '') AS service,
                           (SELECT MAX(\(messageDate))
                              FROM chat_message_join cj
                              JOIN message cm ON cm.ROWID = cj.message_id
                             WHERE cj.chat_id = c.ROWID) AS last_date,
                           \(unread) AS unread
                      FROM chat c
                   ) sub
            \(unreadOnly ? "WHERE sub.unread > 0" : "")
             ORDER BY sub.last_date IS NULL, sub.last_date DESC
             LIMIT ?
            """

        let rows: [(Int64, String, String, String, String, String?, Int)] =
            try connection.withStatement(sql) { statement in
                sqlite3_bind_int64(statement, 1, Int64(Self.clampLimit(limit)))
                var rows: [(Int64, String, String, String, String, String?, Int)] = []
                while true {
                    switch sqlite3_step(statement) {
                    case SQLITE_ROW:
                        rows.append((
                            sqlite3_column_int64(statement, 0),
                            Self.text(statement, 1),
                            Self.text(statement, 2),
                            Self.text(statement, 3),
                            Self.text(statement, 4),
                            Self.optionalDateText(statement, 5),
                            Int(sqlite3_column_int64(statement, 6))
                        ))
                    case SQLITE_DONE:
                        return rows
                    default:
                        throw StoreError.queryFailed(connection.lastError())
                    }
                }
            }

        guard !rows.isEmpty else { return [] }
        let participants = try participants(forChatIDs: rows.map(\.0))
        return rows.map { row in
            let displayName = row.3.isEmpty ? nil : row.3
            return Chat(
                id: row.0,
                guid: row.2,
                identifier: row.1,
                name: displayName ?? row.1,
                displayName: displayName,
                service: row.4,
                isGroup: row.2.contains(";+;") || row.1.contains(";+;"),
                participants: participants[row.0] ?? [],
                lastMessageAt: row.5,
                unreadCount: row.6
            )
        }
    }

    public func sendTarget(chatID: Int64) throws -> ChatSendTarget? {
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
