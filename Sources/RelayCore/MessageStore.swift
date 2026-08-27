import Foundation
import SQLite3

/// SQLite's SQLITE_TRANSIENT is not exposed to Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// Read-only accessor for the macOS Messages database (`chat.db`).
///
/// The store never writes to the database. All timestamps crossing this API
/// are ISO 8601 strings in UTC. `message.date` is seconds (or nanoseconds on
/// newer schemas) since Apple's reference date, which equals Swift's
/// `Date(timeIntervalSinceReferenceDate:)`.
public final class MessageStore: @unchecked Sendable {

    public enum StoreError: Error, CustomStringConvertible {
        case cannotOpen(String)
        case queryFailed(String)

        public var description: String {
            switch self {
            case .cannotOpen(let detail):
                return "Cannot open Messages database: \(detail)"
            case .queryFailed(let detail):
                return "Messages database query failed: \(detail)"
            }
        }
    }

    private let db: OpaquePointer?
    public let path: String

    /// Serializes statement execution; the connection is opened with
    /// SQLITE_OPEN_FULLMUTEX but we keep query granularity coarse anyway.
    private let lock = NSLock()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 returned \(rc)"
            sqlite3_close(handle)
            throw StoreError.cannotOpen(detail)
        }
        self.db = opened
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Status

    public func status() -> DatabaseStatus {
        var ready = false
        var failure: String?
        do {
            _ = try firstColumn("SELECT count(*) FROM chat LIMIT 1")
            ready = true
        } catch {
            failure = String(describing: error)
        }
        return DatabaseStatus(ready: ready, path: path, fingerprint: fingerprint(), error: failure)
    }

    /// Identifies this exact database instance. Cursors (`since_rowid`) are
    /// scoped to one instance; clients must discard cursors when the
    /// fingerprint changes (restore/migration).
    private func fingerprint() -> String {
        let pageCount = (try? firstColumn("PRAGMA page_count")) ?? -1
        let userVersion = (try? firstColumn("PRAGMA user_version")) ?? -1
        var size: UInt64 = 0
        var mtime: Double = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
        return "pages=\(pageCount);uv=\(userVersion);size=\(size);mtime=\(mtime)"
    }

    // MARK: - Chats

    public func chats(limit: Int = 20, unreadOnly: Bool = false) throws -> [Chat] {
        let sql = """
            SELECT sub.rowid, sub.identifier, sub.guid, sub.display_name,
                   sub.service, sub.last_date, sub.unread
            FROM (
                SELECT c.ROWID AS rowid,
                       COALESCE(c.chat_identifier, '') AS identifier,
                       COALESCE(c.guid, '') AS guid,
                       COALESCE(c.display_name, '') AS display_name,
                       COALESCE(c.service_name, '') AS service,
                       (SELECT MAX(cm.date)
                          FROM chat_message_join cj
                          JOIN message cm ON cm.ROWID = cj.message_id
                         WHERE cj.chat_id = c.ROWID) AS last_date,
                       (SELECT COUNT(*)
                          FROM chat_message_join cj
                          JOIN message cm ON cm.ROWID = cj.message_id
                         WHERE cj.chat_id = c.ROWID
                           AND cm.is_from_me = 0 AND cm.is_read = 0) AS unread
                FROM chat c
            ) sub
            \(unreadOnly ? "WHERE sub.unread > 0" : "")
            ORDER BY sub.last_date IS NULL, sub.last_date DESC
            LIMIT ?
            """
        lock.lock()
        defer { lock.unlock() }
        let rows: [(Int64, String, String, String, String, String?, Int)] = try withStatement(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(Self.clampLimit(limit)))
            var out: [(Int64, String, String, String, String, String?, Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append((
                    sqlite3_column_int64(stmt, 0),
                    Self.text(stmt, 1),
                    Self.text(stmt, 2),
                    Self.text(stmt, 3),
                    Self.text(stmt, 4),
                    Self.optionalDateText(stmt, 5),
                    Int(sqlite3_column_int64(stmt, 6))
                ))
            }
            return out
        }

        guard !rows.isEmpty else { return [] }
        let participants = try self.participants(forChatIDs: rows.map(\.0))
        return rows.map { row in
            let displayName = row.3.isEmpty ? nil : row.3
            let isGroup = row.2.contains(";+;") || row.1.contains(";+;")
            let name = displayName ?? row.1
            return Chat(
                id: row.0,
                guid: row.2,
                identifier: row.1,
                name: name,
                displayName: displayName,
                service: row.4,
                isGroup: isGroup,
                participants: participants[row.0] ?? [],
                lastMessageAt: row.5,
                unreadCount: row.6
            )
        }
    }

    private func participants(forChatIDs ids: [Int64]) throws -> [Int64: [String]] {
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT chj.chat_id, h.id
              FROM chat_handle_join chj
              JOIN handle h ON h.ROWID = chj.handle_id
             WHERE chj.chat_id IN (\(placeholders))
            """
        var result: [Int64: [String]] = [:]
        return try withStatement(sql) { stmt in
            for (index, id) in ids.enumerated() {
                sqlite3_bind_int64(stmt, Int32(index + 1), id)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let chatID = sqlite3_column_int64(stmt, 0)
                result[chatID, default: []].append(Self.text(stmt, 1))
            }
            return result
        }
    }

    // MARK: - Messages

    public func messages(
        chatID: Int64,
        limit: Int = 50,
        before: Int64? = nil,
        includeAttachments: Bool = false,
        includeReactions: Bool = false
    ) throws -> [Message] {
        var sql = """
            SELECT m.ROWID, m.guid, COALESCE(m.text, ''), COALESCE(h.id, ''),
                   m.is_from_me, m.date, m.thread_originator_guid,
                   m.date_delivered, m.date_read,
                   m.associated_message_type, m.associated_message_guid
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
              LEFT JOIN handle h ON h.ROWID = m.handle_id
             WHERE cmj.chat_id = ?
            """
        if !includeReactions {
            sql += " AND m.associated_message_type = 0"
        }
        var bindBefore = false
        if before != nil {
            sql += " AND m.ROWID < ?"
            bindBefore = true
        }
        sql += " ORDER BY m.ROWID DESC LIMIT ?"

        lock.lock()
        defer { lock.unlock() }
        let rows: [(Int64, String, String, String, Bool, String?, String?, String?, String?, Int64, String?)] =
            try withStatement(sql) { stmt in
            var index: Int32 = 1
            sqlite3_bind_int64(stmt, index, chatID)
            index += 1
            if bindBefore {
                sqlite3_bind_int64(stmt, index, before!)
                index += 1
            }
            sqlite3_bind_int64(stmt, index, Int64(Self.clampLimit(limit, max: 500)))
            var out: [(Int64, String, String, String, Bool, String?, String?, String?, String?, Int64, String?)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append((
                    sqlite3_column_int64(stmt, 0),
                    Self.text(stmt, 1),
                    Self.text(stmt, 2),
                    Self.text(stmt, 3),
                    sqlite3_column_int64(stmt, 4) != 0,
                    Self.optionalDateText(stmt, 5),
                    sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Self.text(stmt, 6),
                    Self.optionalDateText(stmt, 7),
                    Self.optionalDateText(stmt, 8),
                    sqlite3_column_int64(stmt, 9),
                    sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Self.text(stmt, 10)
                ))
            }
            return out
        }

        var messages = rows.map { row in
            let isReaction = row.9 >= 2000 && row.9 <= 3005
            let reaction = Self.decodeReaction(associatedType: isReaction ? row.9 : nil)
            return Message(
                id: row.0,
                chatId: chatID,
                guid: row.1,
                text: row.2,
                sender: row.3,
                isFromMe: row.4,
                createdAt: row.5 ?? "",
                // Receipts only apply to outgoing messages. On incoming rows
                // chat.db's date_read is the local "I opened this" marker,
                // not a receipt, so it must not surface under the same keys.
                deliveredAt: row.4 ? row.7 : nil,
                readAt: row.4 ? row.8 : nil,
                replyToGuid: row.6,
                isReaction: isReaction ? true : nil,
                reactedToGuid: isReaction ? row.10 : nil,
                reactionType: reaction?.type,
                reactionEmoji: reaction?.emoji,
                isReactionAdd: reaction.map({ $0.added })
            )
        }
        messages.reverse() // ROWID DESC for newest-first window; return chronological.
        if includeAttachments {
            let map = try self.attachments(forMessageIDs: messages.map(\.id))
            for i in messages.indices {
                messages[i].attachments = map[messages[i].id] ?? []
            }
        }
        return messages
    }

    /// Resumable catch-up scan in physical ROWID order. Tapback rows are
    /// suppressed unless `includeReactions` is set. `nextRowid` tracks every
    /// scanned row (including suppressed ones), so persisting it never skips
    /// eligible messages and may replay none.
    public func messagesAfter(
        sinceRowid: Int64,
        chatID: Int64? = nil,
        limit: Int = 100,
        includeAttachments: Bool = false,
        includeReactions: Bool = false
    ) throws -> MessagesPage {
        var sql = """
            SELECT m.ROWID, m.guid, COALESCE(m.text, ''), COALESCE(h.id, ''),
                   m.is_from_me, m.date, m.thread_originator_guid,
                   cmj.chat_id, m.associated_message_type, m.associated_message_guid,
                   m.date_delivered, m.date_read
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
              LEFT JOIN handle h ON h.ROWID = m.handle_id
             WHERE m.ROWID > ?
            """
        var filterByChat = false
        if chatID != nil {
            sql += " AND cmj.chat_id = ?"
            filterByChat = true
        }
        sql += " ORDER BY m.ROWID ASC"

        lock.lock()
        defer { lock.unlock() }
        return try withStatement(sql) { stmt in
            var index: Int32 = 1
            sqlite3_bind_int64(stmt, index, sinceRowid)
            index += 1
            if filterByChat {
                sqlite3_bind_int64(stmt, index, chatID!)
            }

            var visible: [Message] = []
            var nextRowid = sinceRowid
            var hasMore = false

            loop: while true {
                let rc = sqlite3_step(stmt)
                switch rc {
                case SQLITE_ROW:
                    let rowid = sqlite3_column_int64(stmt, 0)
                    nextRowid = rowid
                    let associatedType = sqlite3_column_int64(stmt, 8)
                    let isReaction = associatedType >= 2000 && associatedType <= 3005
                    if !isReaction || includeReactions {
                        let reaction = Self.decodeReaction(associatedType: isReaction ? associatedType : nil)
                        visible.append(Message(
                            id: rowid,
                            chatId: sqlite3_column_int64(stmt, 7),
                            guid: Self.text(stmt, 1),
                            text: Self.text(stmt, 2),
                            sender: Self.text(stmt, 3),
                            isFromMe: sqlite3_column_int64(stmt, 4) != 0,
                            createdAt: Self.optionalDateText(stmt, 5) ?? "",
                            deliveredAt: sqlite3_column_int64(stmt, 4) != 0 ? Self.optionalDateText(stmt, 10) : nil,
                            readAt: sqlite3_column_int64(stmt, 4) != 0 ? Self.optionalDateText(stmt, 11) : nil,
                            replyToGuid: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Self.text(stmt, 6),
                            isReaction: isReaction ? true : nil,
                            reactedToGuid: isReaction ? Self.text(stmt, 9) : nil,
                            reactionType: reaction?.type,
                            reactionEmoji: reaction?.emoji,
                            isReactionAdd: reaction.map({ $0.added })
                        ))
                        if visible.count >= Self.clampLimit(limit, max: 500) { break loop }
                    }
                case SQLITE_DONE:
                    break loop
                default:
                    throw StoreError.queryFailed(lastError())
                }
            }

            // Peek one more row to see whether the stream continues.
            if sqlite3_step(stmt) == SQLITE_ROW {
                hasMore = true
            }

            if includeAttachments {
                let map = try self.attachmentsLocked(forMessageIDs: visible.map(\.id))
                for i in visible.indices {
                    visible[i].attachments = map[visible[i].id] ?? []
                }
            }
            return MessagesPage(messages: visible, nextRowid: nextRowid, hasMore: hasMore)
        }
    }

    /// Substring search over the `text` column only. Text stored solely in
    /// `attributedBody` (typedstream blob) is not searched yet.
    public func search(query: String, exactMatch: Bool = false, limit: Int = 50) throws -> [Message] {
        let pattern: String
        if exactMatch {
            pattern = query
        } else {
            let escaped = query
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            pattern = "%\(escaped)%"
        }
        let sql = """
            SELECT m.ROWID, m.guid, COALESCE(m.text, ''), COALESCE(h.id, ''),
                   m.is_from_me, m.date, m.thread_originator_guid, cmj.chat_id,
                   m.date_delivered, m.date_read
              FROM message m
              JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
              LEFT JOIN handle h ON h.ROWID = m.handle_id
             WHERE m.text LIKE ? ESCAPE '\\'
               AND m.associated_message_type = 0
             ORDER BY m.date DESC
             LIMIT ?
            """
        lock.lock()
        defer { lock.unlock() }
        let rows: [(Int64, String, String, String, Bool, String?, String?, Int64, String?, String?)] = try withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, pattern, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(Self.clampLimit(limit, max: 100)))
            var out: [(Int64, String, String, String, Bool, String?, String?, Int64, String?, String?)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append((
                    sqlite3_column_int64(stmt, 0),
                    Self.text(stmt, 1),
                    Self.text(stmt, 2),
                    Self.text(stmt, 3),
                    sqlite3_column_int64(stmt, 4) != 0,
                    Self.optionalDateText(stmt, 5),
                    sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Self.text(stmt, 6),
                    sqlite3_column_int64(stmt, 7),
                    Self.optionalDateText(stmt, 8),
                    Self.optionalDateText(stmt, 9)
                ))
            }
            return out
        }
        return rows.map { row in
            Message(
                id: row.0,
                chatId: row.7,
                guid: row.1,
                text: row.2,
                sender: row.3,
                isFromMe: row.4,
                createdAt: row.5 ?? "",
                deliveredAt: row.4 ? row.8 : nil,
                readAt: row.4 ? row.9 : nil,
                replyToGuid: row.6
            )
        }
    }

    // MARK: - Streaming support

    /// Highest message ROWID present right now (0 for an empty database).
    /// Serves as the default starting cursor for `/messages/stream`: connect
    /// with no `since_rowid` and only future messages arrive.
    public func maxRowid() throws -> Int64 {
        try firstColumn("SELECT COALESCE(MAX(ROWID), 0) FROM message")
    }

    // MARK: - Attachments

    public struct AttachmentFile: Sendable {
        public var data: Data
        public var mimeType: String
    }

    /// Loads attachment bytes by `attachment.ROWID`. Whole-file read into
    /// memory — acceptable for the skeleton; stream via file IO later.
    public func attachmentData(rowid: Int64) throws -> AttachmentFile? {
        let sql = """
            SELECT COALESCE(filename, ''), COALESCE(mime_type, '')
              FROM attachment
             WHERE ROWID = ?
            """
        lock.lock()
        defer { lock.unlock() }
        let row: (String, String)? = try withStatement(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, rowid)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return (Self.text(stmt, 0), Self.text(stmt, 1))
        }
        guard let row else { return nil }
        let resolved = (row.0 as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: resolved),
              let data = FileManager.default.contents(atPath: resolved) else { return nil }
        return AttachmentFile(data: data, mimeType: row.1.isEmpty ? "application/octet-stream" : row.1)
    }

    private func attachments(forMessageIDs ids: [Int64]) throws -> [Int64: [Attachment]] {
        lock.lock()
        defer { lock.unlock() }
        return try attachmentsLocked(forMessageIDs: ids)
    }

    /// Caller must hold `lock`.
    private func attachmentsLocked(forMessageIDs ids: [Int64]) throws -> [Int64: [Attachment]] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT aj.message_id, COALESCE(a.filename, ''), COALESCE(a.transfer_name, ''),
                   COALESCE(a.mime_type, ''), COALESCE(a.uti, ''), COALESCE(a.total_bytes, 0),
                   COALESCE(a.is_sticker, 0)
              FROM attachment a
              JOIN message_attachment_join aj ON aj.attachment_id = a.ROWID
             WHERE aj.message_id IN (\(placeholders))
            """
        var result: [Int64: [Attachment]] = [:]
        return try withStatement(sql) { stmt in
            for (index, id) in ids.enumerated() {
                sqlite3_bind_int64(stmt, Int32(index + 1), id)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let messageID = sqlite3_column_int64(stmt, 0)
                let filename = Self.text(stmt, 1)
                let resolved = filename.isEmpty ? "" : (filename as NSString).expandingTildeInPath
                result[messageID, default: []].append(Attachment(
                    filename: filename,
                    transferName: Self.text(stmt, 2),
                    mimeType: Self.text(stmt, 3),
                    uti: Self.text(stmt, 4),
                    totalBytes: sqlite3_column_int64(stmt, 5),
                    isSticker: sqlite3_column_int64(stmt, 6) != 0,
                    originalPath: resolved.isEmpty ? nil : resolved,
                    missing: resolved.isEmpty || !FileManager.default.fileExists(atPath: resolved)
                ))
            }
            return result
        }
    }

    // MARK: - Send support

    /// Resolves a local chat rowid to its portable GUID for send targeting.
    public func chatGuid(forRowid rowid: Int64) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return try withStatement("SELECT guid FROM chat WHERE ROWID = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, rowid)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Self.text(stmt, 0)
        }
    }

    /// Every address a chat-targeted send would go to: the chat's guid,
    /// identifier, and participant handles. Used by the recipient allowlist.
    public func sendTargets(chatID: Int64) throws -> [String] {
        var targets: [String] = []
        lock.lock()
        defer { lock.unlock() }
        return try withStatement("""
            SELECT c.guid, COALESCE(c.chat_identifier, ''), COALESCE(h.id, '')
              FROM chat c
              LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
              LEFT JOIN handle h ON h.ROWID = chj.handle_id
             WHERE c.ROWID = ?
            """) { stmt in
            sqlite3_bind_int64(stmt, 1, chatID)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if sqlite3_column_type(stmt, 0) != SQLITE_NULL { targets.append(Self.text(stmt, 0)) }
                let identifier = Self.text(stmt, 1)
                if !identifier.isEmpty { targets.append(identifier) }
                let handle = Self.text(stmt, 2)
                if !handle.isEmpty { targets.append(handle) }
            }
            return targets
        }
    }

    // MARK: - SQLite plumbing

    private func firstColumn(_ sql: String) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return try withStatement(sql) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw StoreError.queryFailed(lastError()) }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    /// Caller must hold `lock`.
    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else {
            throw StoreError.queryFailed(lastError())
        }
        defer { sqlite3_finalize(prepared) }
        do {
            return try body(prepared)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.queryFailed(String(describing: error))
        }
    }

    private func lastError() -> String {
        guard let db else { return "no connection" }
        return String(cString: sqlite3_errmsg(db))
    }

    // MARK: - Value helpers

    struct ReactionInfo {
        var type: String
        var emoji: String?
        var added: Bool
    }

    /// Maps `message.associated_message_type` to a tapback description.
    /// 2000-2005 are adds (love/like/dislike/laugh/emphasis/question),
    /// 3000-3005 the matching removals. Other values in the reaction range
    /// are custom emoji tapbacks whose payload we don't decode yet.
    static func decodeReaction(associatedType: Int64?) -> ReactionInfo? {
        guard let associatedType else { return nil }
        let names = ["love", "like", "dislike", "laugh", "emphasis", "question"]
        if associatedType >= 2000 && associatedType <= 2005 {
            return ReactionInfo(type: names[Int(associatedType - 2000)], emoji: nil, added: true)
        }
        if associatedType >= 3000 && associatedType <= 3005 {
            return ReactionInfo(type: names[Int(associatedType - 3000)], emoji: nil, added: false)
        }
        if associatedType > 2005 && associatedType < 3000 {
            return ReactionInfo(type: "custom", emoji: nil, added: true)
        }
        return nil
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    /// message.date is Apple reference-date seconds; newer schemas use
    /// nanoseconds. Distinguish by magnitude.
    private static func optionalDateText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let raw = sqlite3_column_double(stmt, index)
        guard raw > 0 else { return nil }
        let seconds = abs(raw) > 10_000_000_000 ? raw / 1_000_000_000 : raw
        return isoFormatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private static func clampLimit(_ value: Int, max maximum: Int = 200) -> Int {
        Swift.max(1, Swift.min(value, maximum))
    }
}
