import Foundation
import SQLite3

extension MessageStore {
    public struct AttachmentFile: Sendable {
        public let data: Data
        public let mimeType: String

        public init(data: Data, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    public func attachmentData(rowid: Int64) throws -> AttachmentFile? {
        guard schema.hasTable("attachment"), schema.hasColumn("filename", in: "attachment") else {
            return nil
        }
        let mimeType = schema.expression("mime_type", in: "attachment", alias: "a", fallback: "''")
        let descriptor: (path: String, mimeType: String)? = try connection.withStatement("""
            SELECT COALESCE(a.filename, ''), COALESCE(\(mimeType), '')
              FROM attachment a
             WHERE a.ROWID = ?
            """) { statement in
            sqlite3_bind_int64(statement, 1, rowid)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return (Self.text(statement, 0), Self.text(statement, 1))
            case SQLITE_DONE:
                return nil
            default:
                throw StoreError.queryFailed(connection.lastError())
            }
        }
        guard let descriptor else { return nil }

        let path = (descriptor.path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return AttachmentFile(
            data: data,
            mimeType: descriptor.mimeType.isEmpty ? "application/octet-stream" : descriptor.mimeType
        )
    }

    func hydrateAttachments(in messages: inout [Message]) throws {
        guard !messages.isEmpty else { return }
        let attachments = try attachments(forMessageIDs: messages.map(\.id))
        for index in messages.indices {
            messages[index].attachments = attachments[messages[index].id] ?? []
        }
    }

    private func attachments(forMessageIDs ids: [Int64]) throws -> [Int64: [Attachment]] {
        guard !ids.isEmpty,
              schema.hasTable("attachment"),
              schema.hasTable("message_attachment_join") else {
            return [:]
        }
        let filename = schema.expression("filename", in: "attachment", alias: "a", fallback: "''")
        let transferName = schema.expression("transfer_name", in: "attachment", alias: "a", fallback: "''")
        let mimeType = schema.expression("mime_type", in: "attachment", alias: "a", fallback: "''")
        let uti = schema.expression("uti", in: "attachment", alias: "a", fallback: "''")
        let totalBytes = schema.expression("total_bytes", in: "attachment", alias: "a", fallback: "0")
        let isSticker = schema.expression("is_sticker", in: "attachment", alias: "a", fallback: "0")
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT aj.message_id,
                   a.ROWID,
                   COALESCE(\(filename), ''),
                   COALESCE(\(transferName), ''),
                   COALESCE(\(mimeType), ''),
                   COALESCE(\(uti), ''),
                   COALESCE(\(totalBytes), 0),
                   COALESCE(\(isSticker), 0)
              FROM attachment a
              JOIN message_attachment_join aj ON aj.attachment_id = a.ROWID
             WHERE aj.message_id IN (\(placeholders))
             ORDER BY aj.message_id, a.ROWID
            """
        return try connection.withStatement(sql) { statement in
            for (index, id) in ids.enumerated() {
                sqlite3_bind_int64(statement, Int32(index + 1), id)
            }
            var result: [Int64: [Attachment]] = [:]
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let messageID = sqlite3_column_int64(statement, 0)
                    let storedPath = Self.text(statement, 2)
                    let resolvedPath = storedPath.isEmpty
                        ? ""
                        : (storedPath as NSString).expandingTildeInPath
                    result[messageID, default: []].append(Attachment(
                        id: sqlite3_column_int64(statement, 1),
                        filename: storedPath,
                        transferName: Self.text(statement, 3),
                        mimeType: Self.text(statement, 4),
                        uti: Self.text(statement, 5),
                        totalBytes: sqlite3_column_int64(statement, 6),
                        isSticker: sqlite3_column_int64(statement, 7) != 0,
                        originalPath: resolvedPath.isEmpty ? nil : resolvedPath,
                        missing: resolvedPath.isEmpty || !FileManager.default.fileExists(atPath: resolvedPath)
                    ))
                case SQLITE_DONE:
                    return result
                default:
                    throw StoreError.queryFailed(connection.lastError())
                }
            }
        }
    }
}
