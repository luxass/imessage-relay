extension SQLiteMessageStore {
    static func messageCounts(
        database: SQLiteDatabase,
        conversationID: ConversationID,
        range: MessageCountRange
    ) throws -> MessageCounts {
        let schema = database.schema
        let visible = schema.hasColumn("filter_action", in: "chat_message_join")
            ? "AND duplicate.filter_action = 0" : ""
        var sql = collectionSQL(schema: schema, conversationID: conversationID)
        sql += """
             AND cmj.ROWID = (
                SELECT MIN(duplicate.ROWID) FROM chat_message_join duplicate
                WHERE duplicate.chat_id = cmj.chat_id AND duplicate.message_id = m.ROWID \(visible)
            )
            """
        if let pending = pendingSchedulePredicate(schema) { sql += " AND NOT (\(pending))" }
        let date = timestampSecondsSQL("m.date")
        sql += " AND \(date) < ? ORDER BY \(date) DESC, m.ROWID DESC"
        return try database.withStatement(sql) { statement in
            try statement.bind(conversationID.rawValue, at: 1)
            try statement.bind(range.to.date.timeIntervalSinceReferenceDate, at: 2)
            var counts = MessageCountAccumulator(range: range)
            while try statement.step() == .row {
                try Task.checkCancellation()
                let row = try decode(statement)
                let record = Record(row: row, message: try SQLiteRows.message(row))
                if let date = record.message.createdAt?.date,
                   date < range.from.date, !counts.hasPendingPreview { break }
                counts.add(record)
            }
            counts.finishPreviewGroup()
            return MessageCounts(conversationID: conversationID, range: range, sent: counts.sent, received: counts.received)
        }
    }

    // Streaming summaries preserve preview groups across the date boundary without
    // retaining the conversation or loading attachment files.
    private struct MessageCountAccumulator {
        let range: MessageCountRange
        private(set) var sent = 0
        private(set) var received = 0
        private var group: URLPreviewGroup?
        private var physicalInRange = 0
        private var olderStandaloneInRange = 0

        var hasPendingPreview: Bool { group != nil }

        init(range: MessageCountRange) { self.range = range }

        mutating func add(_ record: Record) {
            if var pending = group {
                if pending.appendOlder(record) {
                    group = pending
                    if inRange(record) { physicalInRange += 1 }
                    if containsURL(record.message.text) {
                        olderStandaloneInRange = 0
                    } else if inRange(record) {
                        olderStandaloneInRange += 1
                    }
                    if !isURLPreview(record) { finishPreviewGroup() }
                    return
                }
                finishPreviewGroup()
            }
            if isURLPreview(record) {
                group = URLPreviewGroup(newest: record)
                physicalInRange = inRange(record) ? 1 : 0
                olderStandaloneInRange = 0
            } else if inRange(record) {
                increment(1, isFromMe: record.row.isFromMe)
            }
        }

        mutating func finishPreviewGroup() {
            guard let group else { return }
            let count: Int
            if let root = group.logicalRoot {
                count = (inRange(root) ? 1 : 0) + olderStandaloneInRange
            } else {
                count = physicalInRange
            }
            increment(count, isFromMe: group.newest.row.isFromMe)
            self.group = nil
        }

        private func inRange(_ record: Record) -> Bool {
            guard let date = record.message.createdAt?.date else { return false }
            return date >= range.from.date && date < range.to.date
        }

        private mutating func increment(_ count: Int, isFromMe: Bool) {
            if isFromMe { sent += count } else { received += count }
        }
    }
}
