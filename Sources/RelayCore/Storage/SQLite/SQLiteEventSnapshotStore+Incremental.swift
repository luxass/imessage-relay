import SQLite3

extension SQLiteEventSnapshotStore {
    static func incrementalBatch(
        database: SQLiteDatabase,
        positions: IncrementalPositions,
        limit: Int
    ) throws -> IncrementalBatch {
        try database.withReadTransaction {
            let dataVersion = try database.dataVersion()
            let candidates = try messageCandidates(
                database: database,
                after: positions.messageRowID,
                limit: limit
            )
            let read = try stateChanges(
                database: database,
                column: "date_read",
                after: positions.read,
                limit: limit
            )
            let delivery = try stateChanges(
                database: database,
                column: "date_delivered",
                after: positions.delivery,
                limit: limit
            )
            let media = try mediaChanges(
                database: database,
                after: positions.attachmentJoinRowID,
                limit: limit
            )
            let candidateRowIDs = Set(candidates.map(\.rowID))
            var next = positions
            next.messageRowID = candidateRowIDs.max() ?? positions.messageRowID
            next.read = read.position
            next.delivery = delivery.position
            next.attachmentJoinRowID = media.lastRowID
            return IncrementalBatch(
                dataVersion: dataVersion,
                candidates: candidates,
                readUpdates: read.messages,
                deliveryUpdates: delivery.messages,
                media: media.values,
                positions: next,
                hasMore: candidateRowIDs.count == limit
                    || read.hasMore
                    || delivery.hasMore
                    || media.hasMore,
                readMetrics: read.metrics,
                deliveryMetrics: delivery.metrics
            )
        }
    }

    private static func messageCandidates(
        database: SQLiteDatabase,
        after rowID: Int64,
        limit: Int
    ) throws -> [MessageCandidate] {
        let sql = """
            WITH candidates AS (
                SELECT ROWID
                FROM message
                WHERE ROWID > ?
                ORDER BY ROWID
                LIMIT ?
            )
            \(messageStateSelect(database.schema))
            JOIN candidates candidate ON candidate.ROWID = m.ROWID
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                \(chatJoinFilter(database.schema, alias: "cmj"))
            LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            ORDER BY m.ROWID, c.ROWID
            """
        return try database.withStatement(sql) { statement in
            try statement.bind(rowID, at: 1)
            try statement.bind(Int64(limit), at: 2)
            var values: [MessageCandidate] = []
            var seen: Set<Int64> = []
            while try statement.step() == .row {
                let candidateRowID = try statement.int64(0)
                guard seen.insert(candidateRowID).inserted else { continue }
                values.append(try messageCandidate(statement, rowID: candidateRowID))
            }
            return values
        }
    }

    private static func stateChanges(
        database: SQLiteDatabase,
        column: String,
        after position: CompoundPosition,
        limit: Int
    ) throws -> (
        messages: [ObservedMessage],
        position: CompoundPosition,
        hasMore: Bool,
        metrics: QueryMetrics
    ) {
        guard database.schema.hasColumn(column, in: "message"),
              database.schema.hasLeadingIndex(on: column, in: "message") else {
            return ([], position, false, QueryMetrics(fullScanSteps: 0, virtualMachineSteps: 0))
        }
        let reactionFilter = nonReactionPredicate(database.schema, alias: "m")
        let sql = """
            WITH candidates AS (
                SELECT m.ROWID
                FROM message m
                WHERE (m.\(column), m.ROWID) > (?, ?)
                  \(reactionFilter)
                ORDER BY m.\(column), m.ROWID
                LIMIT ?
            )
            \(messageStateSelect(database.schema))
            JOIN candidates candidate ON candidate.ROWID = m.ROWID
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                \(chatJoinFilter(database.schema, alias: "cmj"))
            LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            ORDER BY m.\(column), m.ROWID, c.ROWID
            """
        return try database.withStatement(sql) { statement in
            try position.value.bind(to: statement, at: 1)
            try statement.bind(position.rowID, at: 2)
            try statement.bind(Int64(limit), at: 3)
            var messages: [ObservedMessage] = []
            var seen: Set<Int64> = []
            var next = position
            while try statement.step() == .row {
                let rowID = try statement.int64(0)
                guard seen.insert(rowID).inserted else { continue }
                next = CompoundPosition(
                    value: try statement.number(column == "date_read" ? 9 : 8) ?? .integer(0),
                    rowID: rowID
                )
                if let message = try observedMessage(statement) { messages.append(message) }
            }
            return (
                messages,
                next,
                seen.count == limit,
                QueryMetrics(
                    fullScanSteps: try statement.status(SQLITE_STMTSTATUS_FULLSCAN_STEP),
                    virtualMachineSteps: try statement.status(SQLITE_STMTSTATUS_VM_STEP)
                )
            )
        }
    }

    static func targetedStateChanges(
        database: SQLiteDatabase,
        after rowID: Int64,
        limit: Int
    ) throws -> TargetedBatch {
        let reactionFilter = nonReactionPredicate(database.schema, alias: "m")
        let sql = """
            WITH candidates AS (
                SELECT ROWID
                FROM message m
                WHERE ROWID > ? \(reactionFilter)
                ORDER BY ROWID
                LIMIT ?
            )
            \(messageStateSelect(database.schema))
            JOIN candidates candidate ON candidate.ROWID = m.ROWID
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                \(chatJoinFilter(database.schema, alias: "cmj"))
            LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            ORDER BY m.ROWID, c.ROWID
            """
        return try database.withStatement(sql) { statement in
            try statement.bind(rowID, at: 1)
            try statement.bind(Int64(limit), at: 2)
            var candidates: [MessageCandidate] = []
            var seen: Set<Int64> = []
            var lastRowID = rowID
            while try statement.step() == .row {
                let currentRowID = try statement.int64(0)
                guard seen.insert(currentRowID).inserted else { continue }
                lastRowID = currentRowID
                candidates.append(try messageCandidate(statement, rowID: currentRowID))
            }
            return TargetedBatch(
                candidates: candidates,
                nextRowID: seen.count == limit ? lastRowID : 0
            )
        }
    }

    static func refreshMessageCandidates(
        database: SQLiteDatabase,
        rowIDs: [Int64]
    ) throws -> [MessageCandidate] {
        guard !rowIDs.isEmpty else { return [] }
        let placeholders = rowIDs.map { _ in "?" }.joined(separator: ",")
        let sql = """
            \(messageStateSelect(database.schema))
            LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                \(chatJoinFilter(database.schema, alias: "cmj"))
            LEFT JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE m.ROWID IN (\(placeholders))
            ORDER BY m.ROWID, c.ROWID
            """
        return try database.withStatement(sql) { statement in
            for (offset, rowID) in rowIDs.enumerated() {
                try statement.bind(rowID, at: Int32(offset + 1))
            }
            var candidates: [MessageCandidate] = []
            var seen: Set<Int64> = []
            while try statement.step() == .row {
                let rowID = try statement.int64(0)
                guard seen.insert(rowID).inserted else { continue }
                candidates.append(try messageCandidate(statement, rowID: rowID))
            }
            return candidates
        }
    }

    static func refreshMedia(
        database: SQLiteDatabase,
        keys: [MediaKey]
    ) throws -> [ObservedMedia] {
        let mediaIDs = Array(Set(keys.map { $0.mediaID.rawValue }))
        let requested = Set(keys)
        let placeholders = mediaIDs.map { _ in "?" }.joined(separator: ",")
        return try database.withStatement("""
            SELECT m.guid, a.guid, a.filename
            FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            JOIN message m ON m.ROWID = maj.message_id
            WHERE a.guid IN (\(placeholders))
            ORDER BY maj.ROWID
            """) { statement in
                for (offset, mediaID) in mediaIDs.enumerated() {
                    try statement.bind(mediaID, at: Int32(offset + 1))
                }
                var values: [ObservedMedia] = []
                while try statement.step() == .row {
                    let key = MediaKey(
                        messageID: try MessageID(validating: statement.text(0)),
                        mediaID: try MediaID(validating: statement.text(1))
                    )
                    guard requested.contains(key) else { continue }
                    values.append(ObservedMedia(
                        key: key,
                        path: try statement.optionalText(2)
                    ))
                }
                return values
            }
    }

    private static func mediaChanges(
        database: SQLiteDatabase,
        after rowID: Int64,
        limit: Int
    ) throws -> (values: [ObservedMedia], lastRowID: Int64, hasMore: Bool) {
        try database.withStatement("""
            SELECT maj.ROWID, m.guid, a.guid, a.filename
            FROM message_attachment_join maj
            JOIN message m ON m.ROWID = maj.message_id
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.ROWID > ?
            ORDER BY maj.ROWID
            LIMIT ?
            """) { statement in
                try statement.bind(rowID, at: 1)
                try statement.bind(Int64(limit), at: 2)
                var values: [ObservedMedia] = []
                var lastRowID = rowID
                while try statement.step() == .row {
                    lastRowID = try statement.int64(0)
                    let key = MediaKey(
                        messageID: try MessageID(validating: statement.text(1)),
                        mediaID: try MediaID(validating: statement.text(2))
                    )
                    values.append(ObservedMedia(
                        key: key,
                        path: try statement.optionalText(3)
                    ))
                }
                return (values, lastRowID, values.count == limit)
            }
    }

    private static func messageStateSelect(_ schema: SchemaInspector) -> String {
        let error = schema.expression("error", table: "message", alias: "m", fallback: "NULL")
        let sent = schema.expression("is_sent", table: "message", alias: "m", fallback: "NULL")
        let delivered = schema.expression("is_delivered", table: "message", alias: "m", fallback: "NULL")
        let read = schema.expression("is_read", table: "message", alias: "m", fallback: "NULL")
        let deliveredDate = schema.expression(
            "date_delivered", table: "message", alias: "m", fallback: "NULL"
        )
        let readDate = schema.expression("date_read", table: "message", alias: "m", fallback: "NULL")
        let associatedGUID = schema.expression(
            "associated_message_guid", table: "message", alias: "m", fallback: "NULL"
        )
        let associatedType = schema.expression(
            "associated_message_type", table: "message", alias: "m", fallback: "NULL"
        )
        return """
            SELECT m.ROWID, m.guid, c.guid, m.is_from_me, \(error), \(sent),
                   \(delivered), \(read), \(deliveredDate), \(readDate),
                   \(associatedGUID), \(associatedType)
            FROM message m
            """
    }

    private static func messageCandidate(
        _ statement: SQLiteStatement,
        rowID: Int64
    ) throws -> MessageCandidate {
        let associatedType = try statement.optionalInt64(11)
        if isReaction(associatedType) {
            let reactionID = try MessageID(validating: statement.text(1))
            let target = normalizedAssociatedGUID(try statement.optionalText(10))
                .flatMap { try? MessageID(validating: $0) }
            return MessageCandidate(
                rowID: rowID,
                message: nil,
                reaction: target.map {
                    ObservedReaction(
                        rowID: rowID,
                        messageID: $0,
                        reactionID: reactionID,
                        action: (associatedType ?? 0) >= 3000 ? .removed : .added
                    )
                }
            )
        }
        return MessageCandidate(
            rowID: rowID,
            message: try observedMessage(statement),
            reaction: nil
        )
    }

    private static func observedMessage(_ statement: SQLiteStatement) throws -> ObservedMessage? {
        guard let conversationGUID = try statement.optionalText(2) else { return nil }
        let messageID = try MessageID(validating: statement.text(1))
        let isFromMe = try statement.int64(3) != 0
        let row = MessageRow(
            rowID: try statement.int64(0),
            guid: messageID.rawValue,
            conversationGUID: conversationGUID,
            text: nil,
            decodedBody: nil,
            handle: nil,
            originalHandle: nil,
            isFromMe: isFromMe,
            date: nil,
            error: try statement.optionalInt64(4),
            isSent: try SQLiteRows.bool(statement, 5),
            isDelivered: try SQLiteRows.bool(statement, 6),
            isRead: try SQLiteRows.bool(statement, 7),
            dateDelivered: try statement.number(8),
            dateRead: try statement.number(9),
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
        return ObservedMessage(
            rowID: row.rowID,
            messageID: messageID,
            conversationID: try ConversationID(validating: conversationGUID),
            isFromMe: isFromMe,
            deliveryState: SQLiteRows.deliveryState(row),
            readState: SQLiteRows.readState(row)
        )
    }

    private static func chatJoinFilter(_ schema: SchemaInspector, alias: String) -> String {
        schema.hasColumn("filter_action", in: "chat_message_join")
            ? "AND \(alias).filter_action = 0"
            : ""
    }

    private static func nonReactionPredicate(_ schema: SchemaInspector, alias: String) -> String {
        guard schema.hasColumn("associated_message_type", in: "message") else { return "" }
        return """
            AND NOT (COALESCE(\(alias).associated_message_type, 0) BETWEEN 2000 AND 2006)
            AND NOT (COALESCE(\(alias).associated_message_type, 0) BETWEEN 3000 AND 3006)
            """
    }

    private static func isReaction(_ value: Int64?) -> Bool {
        guard let value else { return false }
        return (2000...2006).contains(value) || (3000...3006).contains(value)
    }

    private static func normalizedAssociatedGUID(_ value: String?) -> String? {
        guard let value else { return nil }
        if value.hasPrefix("p:"), let slash = value.firstIndex(of: "/") {
            return String(value[value.index(after: slash)...])
        }
        if value.hasPrefix("bp:") { return String(value.dropFirst(3)) }
        return value
    }
}
