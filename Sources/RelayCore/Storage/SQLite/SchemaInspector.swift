import SQLite3

struct SchemaInspector: Sendable {
    private let columnsByTable: [String: Set<String>]

    init(database: OpaquePointer) throws {
        let tableNames = [
            "attachment",
            "chat",
            "chat_handle_join",
            "chat_message_join",
            "handle",
            "message",
            "message_attachment_join",
        ]
        var result: [String: Set<String>] = [:]
        for table in tableNames {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_xinfo(\(table))", -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SQLiteStorageError.queryFailed("Could not inspect table \(table).")
            }
            defer { sqlite3_finalize(statement) }
            var columns: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) {
                    columns.insert(String(cString: name).lowercased())
                }
            }
            result[table] = columns
        }
        columnsByTable = result
    }

    func hasTable(_ table: String) -> Bool {
        !(columnsByTable[table]?.isEmpty ?? true)
    }

    func hasColumn(_ column: String, in table: String) -> Bool {
        columnsByTable[table]?.contains(column.lowercased()) ?? false
    }

    func expression(_ column: String, table: String, alias: String, fallback: String) -> String {
        hasColumn(column, in: table) ? "\(alias).\(column)" : fallback
    }

    func validateRequiredShape() throws {
        let required: [String: [String]] = [
            "chat": ["rowid", "guid", "chat_identifier", "service_name"],
            "handle": ["rowid", "id", "service"],
            "message": ["rowid", "guid", "text", "handle_id", "is_from_me", "date"],
            "chat_message_join": ["chat_id", "message_id"],
            "chat_handle_join": ["chat_id", "handle_id"],
            "attachment": ["rowid", "guid", "filename"],
            "message_attachment_join": ["message_id", "attachment_id"],
        ]
        var missing: [String] = []
        for (table, columns) in required.sorted(by: { $0.key < $1.key }) {
            guard hasTable(table) else {
                missing.append("table \(table)")
                continue
            }
            for column in columns where !hasColumn(column, in: table) {
                missing.append("\(table).\(column)")
            }
        }
        guard missing.isEmpty else { throw SQLiteStorageError.incompatibleSchema(missing) }
    }
}
