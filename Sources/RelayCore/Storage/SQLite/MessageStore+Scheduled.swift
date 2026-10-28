import Foundation

extension SQLiteMessageStore {
    static func scheduled(
        database: SQLiteDatabase,
        options: ScheduledMessageListOptions,
        asOf: Date
    ) throws -> PaginatedResponse<Message> {
        let schema = database.schema
        guard ["schedule_type", "schedule_state", "is_sent"].allSatisfy({ schema.hasColumn($0, in: "message") }) else {
            throw RelayServiceError.unsupportedCapability("Scheduled messages require schedule and sent-state columns.")
        }
        let identity = try database.identity()
        let signature = CursorCodec.signature(["scheduled", String(options.includeAttachments)])
        let cursor = try CursorCodec.decode(
            options.cursor, route: "scheduled_messages", databaseIdentity: identity, querySignature: signature
        )
        guard cursor?.searchPreview == nil, cursor == nil || cursor?.date != nil else {
            throw SQLiteStorageError.invalidCursor
        }
        let limit = max(1, min(options.limit, 200))
        let date = timestampSecondsSQL("m.date")
        var sql = collectionSQL(schema: schema, conversationID: nil)
        // Recognize the known Send Later shape, not every nonzero schedule marker.
        sql += " AND m.is_from_me = 1 AND m.schedule_type = 2 AND m.schedule_state = 1"
        for column in ["is_sent", "is_delivered", "date_delivered", "error", "date_retracted"] {
            sql += " AND COALESCE(\(schema.expression(column, table: "message", alias: "m", fallback: "0")), 0) = 0"
        }
        sql += " AND \(date) >= ?"
        if cursor != nil { sql += " AND (\(date) > ? OR (\(date) = ? AND m.ROWID > ?))" }
        sql += " ORDER BY \(date), m.ROWID LIMIT ?"
        var records = try database.withStatement(sql) { statement in
            try statement.bind(asOf.timeIntervalSinceReferenceDate, at: 1)
            var binding: Int32 = 2
            if let cursor, let value = cursor.date?.doubleValue {
                let seconds = abs(value) > 10_000_000_000 ? value / 1_000_000_000 : value
                try statement.bind(seconds, at: binding)
                try statement.bind(seconds, at: binding + 1)
                try statement.bind(cursor.rowID, at: binding + 2)
                binding += 3
            }
            try statement.bind(Int64(limit + 1), at: binding)
            var values: [Record] = []
            while try statement.step() == .row {
                let row = try decode(statement)
                values.append(Record(row: row, message: try SQLiteRows.message(row)))
            }
            return values
        }
        let hasMore = records.count > limit
        records = Array(records.prefix(limit))
        try hydrate(database: database, records: &records, attachments: options.includeAttachments, reactions: true)
        let next = try hasMore ? records.last.map {
            try CursorCodec.encode(
                route: "scheduled_messages", databaseIdentity: identity, querySignature: signature,
                date: $0.row.date, rowID: $0.row.rowID
            )
        } : nil
        return PaginatedResponse(items: records.map(\.message), nextCursor: next, hasMore: hasMore)
    }

    static func timestampSecondsSQL(_ column: String) -> String {
        "(CASE WHEN ABS(\(column)) > 10000000000 THEN CAST(\(column) AS REAL) / 1000000000 ELSE \(column) END)"
    }
}
