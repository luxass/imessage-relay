import Foundation
import NIOPosix
import SQLite3
import Darwin

private final class AttachmentDescriptor: @unchecked Sendable {
    let value: Int32

    init(_ value: Int32) { self.value = value }
    deinit { close(value) }
}

private func openRegularAttachment(
    at fileURL: URL,
    within attachmentDirectory: URL
) -> (descriptor: Int32, byteCount: Int64)? {
    let directoryComponents = attachmentDirectory.standardizedFileURL.pathComponents
    let fileComponents = fileURL.standardizedFileURL.pathComponents
    guard fileComponents.count > directoryComponents.count,
          fileComponents.prefix(directoryComponents.count).elementsEqual(directoryComponents) else {
        return nil
    }

    var directoryDescriptor = open(
        attachmentDirectory.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard directoryDescriptor >= 0 else { return nil }
    defer { close(directoryDescriptor) }

    let relativeComponents = fileComponents.dropFirst(directoryComponents.count)
    for component in relativeComponents.dropLast() {
        let nextDescriptor = openat(
            directoryDescriptor,
            component,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard nextDescriptor >= 0 else { return nil }
        close(directoryDescriptor)
        directoryDescriptor = nextDescriptor
    }

    guard let filename = relativeComponents.last else { return nil }
    let descriptor = openat(
        directoryDescriptor,
        filename,
        O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { return nil }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG,
          status.st_size >= 0 else {
        close(descriptor)
        return nil
    }
    return (descriptor, status.st_size)
}

extension MessageStore {
    public struct AttachmentResource: Sendable {
        private static let maximumChunkLength = 128 * 1024

        public let fileURL: URL
        public let mimeType: String
        public let byteCount: Int64
        private let descriptor: AttachmentDescriptor
        private let threadPool: NIOThreadPool

        init(
            fileURL: URL,
            mimeType: String,
            descriptorValue: Int32,
            byteCount: Int64,
            threadPool: NIOThreadPool
        ) {
            self.fileURL = fileURL
            self.mimeType = mimeType
            descriptor = AttachmentDescriptor(descriptorValue)
            self.byteCount = byteCount
            self.threadPool = threadPool
        }

        public func readChunk(atOffset offset: Int64, upToCount count: Int) async throws -> Data {
            guard offset >= 0, count > 0 else { return Data() }
            let byteCount = byteCount
            let descriptor = descriptor
            return try await threadPool.runIfActive {
                var data = Data(count: min(
                    Self.maximumChunkLength,
                    count,
                    Int(max(0, byteCount - offset))
                ))
                let bytesRead = try data.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return 0 }
                    let result = pread(descriptor.value, baseAddress, bytes.count, offset)
                    guard result >= 0 else {
                        throw CocoaError(
                            .fileReadUnknown,
                            userInfo: [NSUnderlyingErrorKey: POSIXError(.init(rawValue: errno)!)]
                        )
                    }
                    return result
                }
                data.count = bytesRead
                return data
            }
        }

    }

    public struct AttachmentFile: Sendable {
        public let data: Data
        public let mimeType: String

        public init(data: Data, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

}

extension SQLiteMessageStore {
    func attachmentResource(
        rowid: Int64,
        threadPool: NIOThreadPool
    ) throws -> MessageStore.AttachmentResource? {
        guard schema.hasTable("attachment"),
              schema.hasColumn("filename", in: "attachment"),
              schema.hasTable("message_attachment_join"),
              schema.hasTable("message") else {
            return nil
        }
        let mimeType = schema.expression("mime_type", in: "attachment", alias: "a", fallback: "''")
        let descriptor: (path: String, mimeType: String)? = try connection.withStatement("""
            SELECT COALESCE(a.filename, ''), COALESCE(\(mimeType), '')
             FROM attachment a
             WHERE a.ROWID = ?
               AND EXISTS (
                   SELECT 1
                     FROM message_attachment_join aj
                     JOIN message m ON m.ROWID = aj.message_id
                    WHERE aj.attachment_id = a.ROWID
               )
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

        let fileURL = URL(fileURLWithPath: (descriptor.path as NSString).expandingTildeInPath)
        let attachmentDirectory = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent("Attachments", isDirectory: true)
        guard let opened = openRegularAttachment(
            at: fileURL,
            within: attachmentDirectory
        ) else {
            return nil
        }
        return MessageStore.AttachmentResource(
            fileURL: fileURL,
            mimeType: descriptor.mimeType.isEmpty ? "application/octet-stream" : descriptor.mimeType,
            descriptorValue: opened.descriptor,
            byteCount: opened.byteCount,
            threadPool: threadPool
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
