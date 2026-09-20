import Foundation
import SQLite3

public final class SQLiteMediaStore: MessageMediaStoring, Sendable {
    private let executor: SQLiteExecutor
    private let attachmentDirectory: URL

    init(executor: SQLiteExecutor, attachmentDirectory: URL) {
        self.executor = executor
        self.attachmentDirectory = attachmentDirectory.standardizedFileURL
    }

    public func media(id: MediaID) async throws -> ReadableMedia? {
        let attachmentDirectory = attachmentDirectory
        return try await executor.run { database in
            try Self.media(database: database, id: id, attachmentDirectory: attachmentDirectory)
        }
    }

    private static func media(
        database: SQLiteDatabase,
        id: MediaID,
        attachmentDirectory: URL
    ) throws -> ReadableMedia? {
        let schema = database.schema
        let transferName = schema.expression("transfer_name", table: "attachment", alias: "a", fallback: "NULL")
        let mime = schema.expression("mime_type", table: "attachment", alias: "a", fallback: "NULL")
        let size = schema.expression("total_bytes", table: "attachment", alias: "a", fallback: "NULL")
        let sticker = schema.expression("is_sticker", table: "attachment", alias: "a", fallback: "0")
        let row: (path: String?, filename: String?, mime: String?, size: Int64?, isSticker: Bool)? = try database.withStatement("""
            SELECT a.filename, \(transferName), \(mime), \(size), \(sticker)
            FROM attachment a
            WHERE a.guid = ?
              AND EXISTS (
                SELECT 1 FROM message_attachment_join maj
                JOIN message m ON m.ROWID = maj.message_id
                WHERE maj.attachment_id = a.ROWID
              )
            LIMIT 1
            """) { statement in
                sqlite3_bind_text(statement, 1, id.rawValue, -1, sqliteTransient)
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    return (
                        SQLiteValue.optionalText(statement, 0),
                        SQLiteValue.optionalText(statement, 1),
                        SQLiteValue.optionalText(statement, 2),
                        SQLiteValue.optionalInt64(statement, 3),
                        SQLiteRows.bool(statement, 4) ?? false
                    )
                case SQLITE_DONE: return nil
                default: throw SQLiteStorageError.queryFailed(database.lastError())
                }
            }
        guard let row, let storedPath = row.path else { return nil }
        let expanded = (storedPath as NSString).expandingTildeInPath
        guard let opened = openRegularFile(path: expanded, within: attachmentDirectory) else { return nil }
        let reference = MediaReference(
            mediaID: id,
            filename: row.filename,
            mimeType: row.mime,
            byteSize: opened.byteCount,
            source: .messages,
            isSticker: row.isSticker
        )
        return ReadableMedia(
            reference: reference,
            descriptor: opened.descriptor,
            byteCount: opened.byteCount,
            identity: opened.identity
        )
    }
}
