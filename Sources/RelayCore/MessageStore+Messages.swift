import SQLite3

extension SQLiteMessageStore {
    func messages(
        chatID: Int64,
        limit: Int = 50,
        cursor encodedCursor: String? = nil,
        includeAttachments: Bool = false,
        includeReactions: Bool = false,
        query: String? = nil,
        exactMatch: Bool = false
    ) throws -> Page<Message> {
        let signature = messageHistorySignature(
            chatID: chatID,
            includeAttachments: includeAttachments,
            includeReactions: includeReactions,
            query: query,
            exactMatch: exactMatch
        )
        let cursor = try decodePageCursor(encodedCursor, kind: "messages", signature: signature)
        if query != nil, !schema.hasColumn("text", in: "message") {
            return Page(items: [], nextCursor: nil, hasMore: false)
        }
        var sql = """
            SELECT \(messageProjection)
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
              \(handleJoin)
             WHERE cmj.chat_id = ?
            """
        if !includeReactions, let reactionExclusionPredicate {
            sql += " AND \(reactionExclusionPredicate)"
        }
        if query != nil {
            let predicate = exactMatch
                ? "m.text = ? COLLATE NOCASE"
                : "m.text LIKE ? ESCAPE '\\'"
            sql += " AND \(predicate)"
        }
        if cursor != nil {
            sql += " AND m.ROWID < ?"
        }
        sql += " ORDER BY m.ROWID DESC LIMIT ?"

        let visibleLimit = Self.clampLimit(limit, max: 500)
        var messages = try connection.withStatement(sql) { statement in
            var binding: Int32 = 1
            sqlite3_bind_int64(statement, binding, chatID)
            binding += 1
            if let query {
                let pattern = exactMatch ? query : "%\(Self.escapeLike(query))%"
                sqlite3_bind_text(statement, binding, pattern, -1, sqliteTransient)
                binding += 1
            }
            if let cursor {
                sqlite3_bind_int64(statement, binding, cursor.rowid)
                binding += 1
            }
            sqlite3_bind_int64(statement, binding, Int64(visibleLimit + 1))

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
        let hasMore = messages.count > visibleLimit
        messages = Array(messages.prefix(visibleLimit))
        let nextCursor = try hasMore ? messages.last.map {
            try encodePageCursor(kind: "messages", signature: signature, date: nil, rowid: $0.id)
        } : nil
        messages.reverse()
        if includeAttachments {
            try hydrateAttachments(in: &messages)
        }
        return Page(items: messages, nextCursor: nextCursor, hasMore: hasMore)
    }

    private var handleJoin: String {
        guard schema.hasTable("handle"),
              schema.hasColumn("handle_id", in: "message"),
              schema.hasColumn("id", in: "handle") else {
            return ""
        }
        return "LEFT JOIN handle h ON h.ROWID = m.handle_id"
    }

    private var reactionExclusionPredicate: String? {
        guard schema.hasColumn("associated_message_type", in: "message") else { return nil }
        let lowerBound = Self.reactionTypeRange.lowerBound
        let upperBound = Self.reactionTypeRange.upperBound
        return "NOT (COALESCE(m.associated_message_type, 0) BETWEEN \(lowerBound) AND \(upperBound))"
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
        reactionTypeRange.contains(associatedType)
    }

    private static let reactionTypeRange: ClosedRange<Int64> = 2000...3006

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
