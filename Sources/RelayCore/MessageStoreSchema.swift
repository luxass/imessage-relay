import SQLite3

/// Columns present in the installed Messages database. Apple changes this
/// private schema between macOS releases, so optional fields must be selected
/// only when they exist.
struct MessageStoreSchema: Sendable {
    private let columnsByTable: [String: Set<String>]

    init(connection: SQLiteReadConnection) throws {
        let tables = [
            "attachment",
            "chat",
            "chat_handle_join",
            "chat_message_join",
            "handle",
            "message",
            "message_attachment_join",
        ]
        var columns: [String: Set<String>] = [:]
        for table in tables {
            columns[table] = try Self.columns(in: table, connection: connection)
        }
        columnsByTable = columns
    }

    func hasTable(_ table: String) -> Bool {
        !(columnsByTable[table]?.isEmpty ?? true)
    }

    func hasColumn(_ column: String, in table: String) -> Bool {
        columnsByTable[table]?.contains(column.lowercased()) ?? false
    }

    func expression(
        _ column: String,
        in table: String,
        alias: String,
        fallback: String
    ) -> String {
        hasColumn(column, in: table) ? "\(alias).\(column)" : fallback
    }

    private static func columns(
        in table: String,
        connection: SQLiteReadConnection
    ) throws -> Set<String> {
        try connection.withStatement("PRAGMA table_info(\(table))") { statement in
            var columns: Set<String> = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    if let value = sqlite3_column_text(statement, 1) {
                        columns.insert(String(cString: value).lowercased())
                    }
                case SQLITE_DONE:
                    return columns
                default:
                    throw MessageStore.StoreError.queryFailed(connection.lastError())
                }
            }
        }
    }
}
