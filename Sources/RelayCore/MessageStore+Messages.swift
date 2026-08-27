import SQLite3

extension MessageStore {
    public func messages(
        chatID: Int64,
        limit: Int = 50,
        before: Int64? = nil,
        includeAttachments: Bool = false,
        includeReactions: Bool = false
    ) throws -> [Message] {
        var sql = """
            SELECT \(messageProjection)
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
              \(handleJoin)
             WHERE cmj.chat_id = ?
            """
        if !includeReactions, schema.hasColumn("associated_message_type", in: "message") {
            sql += " AND COALESCE(m.associated_message_type, 0) = 0"
        }
        if before != nil {
            sql += " AND m.ROWID < ?"
        }
        sql += " ORDER BY m.ROWID DESC LIMIT ?"

        var messages = try connection.withStatement(sql) { statement in
            var binding: Int32 = 1
            sqlite3_bind_int64(statement, binding, chatID)
            binding += 1
            if let before {
                sqlite3_bind_int64(statement, binding, before)
                binding += 1
            }
            sqlite3_bind_int64(statement, binding, Int64(Self.clampLimit(limit, max: 500)))

            var messages: [Message] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    messages.append(Self.decodeMessage(statement))
                case SQLITE_DONE:
                    return Array(messages.reversed())
                default:
                    throw StoreError.queryFailed(connection.lastError())
                }
            }
        }
        if includeAttachments {
            try hydrateAttachments(in: &messages)
        }
        return messages
    }

    public func messagesAfter(
        sinceRowid: Int64,
        chatID: Int64? = nil,
        limit: Int = 100,
        includeAttachments: Bool = false,
        includeReactions: Bool = false
    ) throws -> MessagesPage {
        let chatJoin = chatID == nil ? uniqueMessageChatJoin : directMessageChatJoin
        var sql = """
            SELECT \(messageProjection)
              FROM message m
              \(chatJoin)
              \(handleJoin)
             WHERE m.ROWID > ?
            """
        if chatID != nil {
            sql += " AND cmj.chat_id = ?"
        }
        sql += " ORDER BY m.ROWID ASC LIMIT ?"

        var page = try connection.withStatement(sql) { statement in
            var binding: Int32 = 1
            sqlite3_bind_int64(statement, binding, sinceRowid)
            binding += 1
            if let chatID {
                sqlite3_bind_int64(statement, binding, chatID)
                binding += 1
            }

            let visibleLimit = Self.clampLimit(limit, max: 500)
            let scanLimit = Swift.max(visibleLimit * 4, 500)
            sqlite3_bind_int64(statement, binding, Int64(scanLimit + 1))
            var messages: [Message] = []
            var nextRowid = sinceRowid
            var hasMore = false
            var scanned = 0

            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    scanned += 1
                    if scanned > scanLimit {
                        return MessagesPage(messages: messages, nextRowid: nextRowid, hasMore: true)
                    }
                    let associatedType = sqlite3_column_int64(statement, 8)
                    let message = Self.decodeMessage(statement)
                    nextRowid = message.id
                    if !Self.isReactionType(associatedType) || includeReactions {
                        messages.append(message)
                        if messages.count >= visibleLimit {
                            let nextResult = sqlite3_step(statement)
                            if nextResult == SQLITE_ROW {
                                hasMore = true
                            } else if nextResult != SQLITE_DONE {
                                throw StoreError.queryFailed(connection.lastError())
                            }
                            return MessagesPage(
                                messages: messages,
                                nextRowid: nextRowid,
                                hasMore: hasMore
                            )
                        }
                    }
                case SQLITE_DONE:
                    return MessagesPage(messages: messages, nextRowid: nextRowid, hasMore: false)
                default:
                    throw StoreError.queryFailed(connection.lastError())
                }
            }
        }
        if includeAttachments {
            try hydrateAttachments(in: &page.messages)
        }
        return page
    }

    public func search(query: String, exactMatch: Bool = false, limit: Int = 50) throws -> [Message] {
        guard schema.hasColumn("text", in: "message") else { return [] }
        let predicate: String
        let pattern: String
        if exactMatch {
            predicate = "m.text = ? COLLATE NOCASE"
            pattern = query
        } else {
            predicate = "m.text LIKE ? ESCAPE '\\'"
            pattern = "%\(Self.escapeLike(query))%"
        }
        let reactionFilter = schema.hasColumn("associated_message_type", in: "message")
            ? "AND COALESCE(m.associated_message_type, 0) = 0"
            : ""
        let date = schema.expression("date", in: "message", alias: "m", fallback: "0")
        let sql = """
            SELECT \(messageProjection)
              FROM message m
              \(uniqueMessageChatJoin)
              \(handleJoin)
             WHERE \(predicate)
               \(reactionFilter)
             ORDER BY \(date) DESC
             LIMIT ?
            """
        return try connection.withStatement(sql) { statement in
            sqlite3_bind_text(statement, 1, pattern, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 2, Int64(Self.clampLimit(limit, max: 100)))
            var messages: [Message] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    messages.append(Self.decodeMessage(statement))
                case SQLITE_DONE:
                    return messages
                default:
                    throw StoreError.queryFailed(connection.lastError())
                }
            }
        }
    }

    public func maxRowid() throws -> Int64 {
        try connection.firstInt64("SELECT COALESCE(MAX(ROWID), 0) FROM message")
    }

    private var handleJoin: String {
        guard schema.hasTable("handle"),
              schema.hasColumn("handle_id", in: "message"),
              schema.hasColumn("id", in: "handle") else {
            return ""
        }
        return "LEFT JOIN handle h ON h.ROWID = m.handle_id"
    }

    private var directMessageChatJoin: String {
        "JOIN chat_message_join cmj ON cmj.message_id = m.ROWID"
    }

    private var uniqueMessageChatJoin: String {
        """
        JOIN (
            SELECT message_id, MIN(chat_id) AS chat_id
              FROM chat_message_join
             GROUP BY message_id
        ) cmj ON cmj.message_id = m.ROWID
        """
    }

    private var messageProjection: String {
        let guid = schema.expression("guid", in: "message", alias: "m", fallback: "''")
        let text = schema.expression("text", in: "message", alias: "m", fallback: "''")
        let sender = handleJoin.isEmpty ? "''" : "h.id"
        let isFromMe = schema.expression("is_from_me", in: "message", alias: "m", fallback: "0")
        let date = schema.expression("date", in: "message", alias: "m", fallback: "NULL")
        let reply = schema.expression("thread_originator_guid", in: "message", alias: "m", fallback: "NULL")
        let reactionType = schema.expression(
            "associated_message_type",
            in: "message",
            alias: "m",
            fallback: "0"
        )
        let reactionGuid = schema.expression(
            "associated_message_guid",
            in: "message",
            alias: "m",
            fallback: "NULL"
        )
        let delivered = schema.expression("date_delivered", in: "message", alias: "m", fallback: "NULL")
        let read = schema.expression("date_read", in: "message", alias: "m", fallback: "NULL")
        return """
            m.ROWID,
            COALESCE(\(guid), ''),
            COALESCE(\(text), ''),
            COALESCE(\(sender), ''),
            \(isFromMe),
            \(date),
            \(reply),
            cmj.chat_id,
            \(reactionType),
            \(reactionGuid),
            \(delivered),
            \(read)
            """
    }

    private static func decodeMessage(_ statement: OpaquePointer) -> Message {
        let isFromMe = sqlite3_column_int64(statement, 4) != 0
        let associatedType = sqlite3_column_int64(statement, 8)
        let reaction = decodeReaction(associatedType: associatedType)
        return Message(
            id: sqlite3_column_int64(statement, 0),
            chatId: sqlite3_column_int64(statement, 7),
            guid: text(statement, 1),
            text: text(statement, 2),
            sender: text(statement, 3),
            isFromMe: isFromMe,
            createdAt: optionalDateText(statement, 5) ?? "",
            deliveredAt: isFromMe ? optionalDateText(statement, 10) : nil,
            readAt: isFromMe ? optionalDateText(statement, 11) : nil,
            replyToGuid: optionalText(statement, 6),
            isReaction: reaction == nil ? nil : true,
            reactedToGuid: reaction == nil ? nil : optionalText(statement, 9),
            reactionType: reaction?.type,
            reactionEmoji: reaction?.emoji,
            isReactionAdd: reaction?.added
        )
    }

    private struct ReactionInfo {
        let type: String
        let emoji: String?
        let added: Bool
    }

    private static func decodeReaction(associatedType: Int64) -> ReactionInfo? {
        let names = ["love", "like", "dislike", "laugh", "emphasis", "question"]
        if (2000...2005).contains(associatedType) {
            return ReactionInfo(type: names[Int(associatedType - 2000)], emoji: nil, added: true)
        }
        if (3000...3005).contains(associatedType) {
            return ReactionInfo(type: names[Int(associatedType - 3000)], emoji: nil, added: false)
        }
        if (2006...2999).contains(associatedType) {
            return ReactionInfo(type: "custom", emoji: nil, added: true)
        }
        if associatedType == 3006 {
            return ReactionInfo(type: "custom", emoji: nil, added: false)
        }
        return nil
    }

    private static func isReactionType(_ associatedType: Int64) -> Bool {
        (2000...3006).contains(associatedType)
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
