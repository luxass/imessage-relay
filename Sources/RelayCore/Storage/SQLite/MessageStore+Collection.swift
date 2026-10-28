extension SQLiteMessageStore {
    static func timestampSecondsSQL(_ column: String) -> String {
        "(CASE WHEN ABS(\(column)) > 10000000000 THEN CAST(\(column) AS REAL) / 1000000000 ELSE \(column) END)"
    }

    static func collectionSQL(schema: SchemaInspector, conversationID: ConversationID?) -> String {
        var sql = """
            SELECT \(projection(schema))
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE 1 = 1
            """
        if conversationID != nil {
            sql += " AND c.guid = ?"
        } else {
            let visible = schema.hasColumn("filter_action", in: "chat_message_join")
                ? "AND canonical.filter_action = 0" : ""
            // Pick one visible membership, including duplicate joins within a chat.
            sql += """
                 AND cmj.ROWID = (
                    SELECT canonical.ROWID FROM chat_message_join canonical
                    JOIN chat canonical_chat ON canonical_chat.ROWID = canonical.chat_id
                    WHERE canonical.message_id = m.ROWID \(visible)
                    ORDER BY canonical_chat.ROWID, canonical.ROWID LIMIT 1
                )
                """
        }
        if schema.hasColumn("associated_message_type", in: "message") {
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 2000 AND 2006)"
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 3000 AND 3006)"
        }
        if schema.hasColumn("filter_action", in: "chat_message_join") {
            sql += " AND cmj.filter_action = 0"
        }
        return sql
    }
}
