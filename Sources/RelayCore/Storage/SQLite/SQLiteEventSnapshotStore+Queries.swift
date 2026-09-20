extension SQLiteEventSnapshotStore {
    static func messages(database: SQLiteDatabase) throws -> [MessageID: ObservedMessage] {
        let schema = database.schema
        let error = schema.expression("error", table: "message", alias: "m", fallback: "NULL")
        let sent = schema.expression("is_sent", table: "message", alias: "m", fallback: "NULL")
        let delivered = schema.expression("is_delivered", table: "message", alias: "m", fallback: "NULL")
        let read = schema.expression("is_read", table: "message", alias: "m", fallback: "NULL")
        let deliveredDate = schema.expression(
            "date_delivered", table: "message", alias: "m", fallback: "NULL"
        )
        let readDate = schema.expression("date_read", table: "message", alias: "m", fallback: "NULL")
        var sql = """
            SELECT m.ROWID, m.guid, c.guid, m.is_from_me, \(error), \(sent),
                   \(delivered), \(read), \(deliveredDate), \(readDate)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE 1 = 1
            """
        if schema.hasColumn("associated_message_type", in: "message") {
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 2000 AND 2006)"
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 3000 AND 3006)"
        }
        if schema.hasColumn("filter_action", in: "chat_message_join") {
            sql += " AND cmj.filter_action = 0"
        }
        sql += " ORDER BY m.ROWID, c.ROWID"

        return try database.withStatement(sql) { statement in
            var values: [MessageID: ObservedMessage] = [:]
            while try statement.step() == .row {
                let messageID = try MessageID(validating: SQLiteValue.text(statement, 1))
                guard values[messageID] == nil else { continue }
                let isFromMe = try statement.int64(3) != 0
                let row = MessageRow(
                    rowID: try statement.int64(0),
                    guid: messageID.rawValue,
                    conversationGUID: try SQLiteValue.text(statement, 2),
                    text: nil,
                    decodedBody: nil,
                    handle: nil,
                    originalHandle: nil,
                    isFromMe: isFromMe,
                    date: nil,
                    error: try SQLiteValue.optionalInt64(statement, 4),
                    isSent: try SQLiteRows.bool(statement, 5),
                    isDelivered: try SQLiteRows.bool(statement, 6),
                    isRead: try SQLiteRows.bool(statement, 7),
                    dateDelivered: try SQLiteNumber.read(statement, 8),
                    dateRead: try SQLiteNumber.read(statement, 9),
                    replyToGUID: nil,
                    threadOriginatorGUID: nil,
                    partCount: nil,
                    balloonBundleID: nil,
                    isAudioMessage: nil,
                    scheduleType: nil,
                    scheduleState: nil,
                    associatedMessageGUID: nil,
                    associatedMessageType: nil
                )
                values[messageID] = ObservedMessage(
                    rowID: row.rowID,
                    messageID: messageID,
                    conversationID: try ConversationID(validating: row.conversationGUID),
                    isFromMe: isFromMe,
                    deliveryState: SQLiteRows.deliveryState(row),
                    readState: SQLiteRows.readState(row)
                )
            }
            return values
        }
    }

    static func reactions(database: SQLiteDatabase) throws -> [MessageID: ObservedReaction] {
        let schema = database.schema
        guard schema.hasColumn("associated_message_guid", in: "message"),
              schema.hasColumn("associated_message_type", in: "message") else { return [:] }
        let normalizedTarget = """
            CASE
              WHEN r.associated_message_guid LIKE 'p:%/%'
                THEN substr(r.associated_message_guid, instr(r.associated_message_guid, '/') + 1)
              WHEN r.associated_message_guid LIKE 'bp:%'
                THEN substr(r.associated_message_guid, 4)
              ELSE r.associated_message_guid
            END
            """
        return try database.withStatement("""
            SELECT r.ROWID, r.guid, \(normalizedTarget), r.associated_message_type
            FROM message r
            JOIN message target ON target.guid = \(normalizedTarget)
            WHERE (r.associated_message_type BETWEEN 2000 AND 2006)
               OR (r.associated_message_type BETWEEN 3000 AND 3006)
            ORDER BY r.ROWID
            """) { statement in
                var values: [MessageID: ObservedReaction] = [:]
                while try statement.step() == .row {
                    let reactionID = try MessageID(validating: SQLiteValue.text(statement, 1))
                    values[reactionID] = ObservedReaction(
                        rowID: try statement.int64(0),
                        messageID: try MessageID(validating: SQLiteValue.text(statement, 2)),
                        reactionID: reactionID,
                        action: try statement.int64(3) >= 3000 ? .removed : .added
                    )
                }
                return values
            }
    }

    static func positions(database: SQLiteDatabase) throws -> IncrementalPositions {
        IncrementalPositions(
            messageRowID: try maximumRowID(database: database, table: "message"),
            attachmentJoinRowID: try maximumRowID(
                database: database,
                table: "message_attachment_join"
            ),
            read: try compoundPosition(database: database, column: "date_read"),
            delivery: try compoundPosition(database: database, column: "date_delivered"),
            targetedRowID: 0
        )
    }

    private static func maximumRowID(database: SQLiteDatabase, table: String) throws -> Int64 {
        try database.withStatement("SELECT COALESCE(MAX(ROWID), 0) FROM \(table)") { statement in
            guard try statement.step() == .row else {
                throw SQLiteStorageError.queryFailed("Could not read the \(table) high watermark.")
            }
            return try statement.int64(0)
        }
    }

    private static func compoundPosition(
        database: SQLiteDatabase,
        column: String
    ) throws -> CompoundPosition {
        guard database.schema.hasColumn(column, in: "message"),
              database.schema.hasLeadingIndex(on: column, in: "message") else {
            return CompoundPosition(value: .integer(0), rowID: 0)
        }
        let reactionFilter = database.schema.hasColumn("associated_message_type", in: "message")
            ? "AND NOT (COALESCE(associated_message_type, 0) BETWEEN 2000 AND 2006)"
                + " AND NOT (COALESCE(associated_message_type, 0) BETWEEN 3000 AND 3006)"
            : ""
        return try database.withStatement("""
            SELECT \(column), ROWID
            FROM message
            WHERE \(column) IS NOT NULL \(reactionFilter)
            ORDER BY \(column) DESC, ROWID DESC
            LIMIT 1
            """) { statement in
                guard try statement.step() == .row else {
                    return CompoundPosition(value: .integer(0), rowID: 0)
                }
                return CompoundPosition(
                    value: try statement.number(0) ?? .integer(0),
                    rowID: try statement.int64(1)
                )
            }
    }

    static func media(database: SQLiteDatabase) throws -> [MediaKey: ObservedMedia] {
        try database.withStatement("""
            SELECT m.guid, a.guid, a.filename
            FROM message_attachment_join maj
            JOIN message m ON m.ROWID = maj.message_id
            JOIN attachment a ON a.ROWID = maj.attachment_id
            ORDER BY maj.message_id, maj.attachment_id
            """) { statement in
                var values: [MediaKey: ObservedMedia] = [:]
                while try statement.step() == .row {
                    let key = MediaKey(
                        messageID: try MessageID(validating: SQLiteValue.text(statement, 0)),
                        mediaID: try MediaID(validating: SQLiteValue.text(statement, 1))
                    )
                    values[key] = ObservedMedia(
                        key: key,
                        path: try SQLiteValue.optionalText(statement, 2)
                    )
                }
                return values
            }
    }
}
