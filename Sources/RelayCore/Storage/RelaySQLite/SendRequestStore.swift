import CryptoKit
import Foundation
import SQLite3

public enum SendRequestReservation: Equatable, Sendable {
    case created
    case replay(SendMessageResponse)
}

public enum SendRequestStorageError: Error, Equatable, Sendable {
    case conflict(RequestID)
    case unavailable(String)
}

public protocol SendRequestStoring: Sendable {
    func reserve(
        requestID: RequestID,
        idempotencyKey: String?,
        fingerprint: String
    ) async throws -> SendRequestReservation
    func record(_ response: SendMessageResponse) async throws
    func response(requestID: RequestID) async throws -> SendMessageResponse?
    func recordCorrelation(
        _ correlation: SendCorrelationCriteria,
        requestID: RequestID
    ) async throws
    func correlation(requestID: RequestID) async throws -> SendCorrelationCriteria?
}

public actor InMemorySendRequestStore: SendRequestStoring {
    private struct IdempotencyEntry: Sendable {
        let fingerprint: String
        let requestID: RequestID
    }

    private var responses: [RequestID: SendMessageResponse] = [:]
    private var idempotency: [String: IdempotencyEntry] = [:]
    private var correlations: [RequestID: SendCorrelationCriteria] = [:]

    public init() {}

    public func reserve(
        requestID: RequestID,
        idempotencyKey: String?,
        fingerprint: String
    ) throws -> SendRequestReservation {
        if let idempotencyKey, let existing = idempotency[idempotencyKey] {
            guard existing.fingerprint == fingerprint else {
                throw SendRequestStorageError.conflict(existing.requestID)
            }
            guard let response = responses[existing.requestID] else {
                throw SendRequestStorageError.unavailable("The existing send request cannot be read.")
            }
            return .replay(response)
        }
        let response = SendMessageResponse.tracking(requestID: requestID, status: .sending)
        responses[requestID] = response
        if let idempotencyKey {
            idempotency[idempotencyKey] = IdempotencyEntry(
                fingerprint: fingerprint,
                requestID: requestID
            )
        }
        return .created
    }

    public func record(_ response: SendMessageResponse) {
        responses[response.requestID] = response
    }

    public func response(requestID: RequestID) -> SendMessageResponse? {
        responses[requestID]
    }

    public func recordCorrelation(
        _ correlation: SendCorrelationCriteria,
        requestID: RequestID
    ) {
        correlations[requestID] = correlation
    }

    public func correlation(requestID: RequestID) -> SendCorrelationCriteria? {
        correlations[requestID]
    }
}

public actor SQLiteSendRequestStore: SendRequestStoring {
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer

        init(handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }

    private let connection: Connection
    private var handle: OpaquePointer { connection.handle }

    public init(path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SendRequestStorageError.unavailable("Cannot create relay state directory: \(error)")
        }

        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let detail = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 returned \(result)"
            sqlite3_close(opened)
            throw SendRequestStorageError.unavailable("Cannot open relay state database: \(detail)")
        }
        do {
            try Self.prepareDatabase(opened, at: url)
        } catch {
            sqlite3_close(opened)
            throw error
        }
        connection = Connection(handle: opened)
    }

    public func reserve(
        requestID: RequestID,
        idempotencyKey: String?,
        fingerprint: String
    ) throws -> SendRequestReservation {
        let digest = idempotencyKey.map(Self.digest)
        try execute("BEGIN IMMEDIATE")
        do {
            if let digest, let existing = try existing(digest: digest) {
                try execute("COMMIT")
                guard existing.fingerprint == fingerprint else {
                    throw SendRequestStorageError.conflict(existing.response.requestID)
                }
                return .replay(existing.response)
            }
            try insert(
                requestID: requestID,
                idempotencyDigest: digest,
                fingerprint: fingerprint
            )
            try execute("COMMIT")
            return .created
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func record(_ response: SendMessageResponse) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try withStatement("""
                UPDATE send_request
                SET status = ?, correlation_status = ?, conversation_id = ?,
                    message_id = NULL, updated_at = ?
                WHERE request_id = ?
                """) { statement in
                bind(response.status.rawValue, to: 1, in: statement)
                bind(response.correlationStatus.rawValue, to: 2, in: statement)
                bind(response.conversationID?.rawValue, to: 3, in: statement)
                bind(Self.timestamp(), to: 4, in: statement)
                bind(response.requestID.rawValue, to: 5, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else {
                    throw unavailable()
                }
            }
            try replaceMessages(response.messages, requestID: response.requestID)
            try replaceMedia(response.media, requestID: response.requestID)
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func response(requestID: RequestID) throws -> SendMessageResponse? {
        let head: ResponseHead? = try withStatement("""
            SELECT request_id, status, correlation_status, conversation_id
            FROM send_request
            WHERE request_id = ?
            """) { statement in
            bind(requestID.rawValue, to: 1, in: statement)
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return try decodeResponseHead(statement)
            case SQLITE_DONE: return nil
            default: throw unavailable()
            }
        }
        return try head.map { try response(from: $0) }
    }

    public func recordCorrelation(
        _ correlation: SendCorrelationCriteria,
        requestID: RequestID
    ) throws {
        let data: Data
        do {
            data = try RelayJSON.encoder.encode(correlation)
        } catch {
            throw SendRequestStorageError.unavailable("Cannot encode send correlation data: \(error)")
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw SendRequestStorageError.unavailable("Cannot encode send correlation data as UTF-8.")
        }
        try withStatement("""
            UPDATE send_request
            SET correlation_json = ?, updated_at = ?
            WHERE request_id = ?
            """) { statement in
            bind(json, to: 1, in: statement)
            bind(Self.timestamp(), to: 2, in: statement)
            bind(requestID.rawValue, to: 3, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else {
                throw unavailable()
            }
        }
    }

    public func correlation(requestID: RequestID) throws -> SendCorrelationCriteria? {
        try withStatement("""
            SELECT correlation_json
            FROM send_request
            WHERE request_id = ?
            """) { statement in
            bind(requestID.rawValue, to: 1, in: statement)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let json = optionalText(statement, index: 0) else { return nil }
                do {
                    return try RelayJSON.decoder.decode(
                        SendCorrelationCriteria.self,
                        from: Data(json.utf8)
                    )
                } catch {
                    throw SendRequestStorageError.unavailable(
                        "The relay state database contains invalid send correlation data."
                    )
                }
            case SQLITE_DONE: return nil
            default: throw unavailable()
            }
        }
    }

    private func existing(digest: String) throws -> (fingerprint: String, response: SendMessageResponse)? {
        let stored: (fingerprint: String, head: ResponseHead)? = try withStatement("""
            SELECT request_id, status, correlation_status, conversation_id, fingerprint
            FROM send_request
            WHERE idempotency_digest = ?
            """) { statement in
            bind(digest, to: 1, in: statement)
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                return (
                    fingerprint: try requiredText(statement, index: 4),
                    head: try decodeResponseHead(statement)
                )
            case SQLITE_DONE: return nil
            default: throw unavailable()
            }
        }
        guard let stored else { return nil }
        return (stored.fingerprint, try response(from: stored.head))
    }

    private func insert(
        requestID: RequestID,
        idempotencyDigest: String?,
        fingerprint: String
    ) throws {
        try withStatement("""
            INSERT INTO send_request (
                request_id, idempotency_digest, fingerprint, status, created_at, updated_at
            ) VALUES (?, ?, ?, 'sending', ?, ?)
            """) { statement in
            let timestamp = Self.timestamp()
            bind(requestID.rawValue, to: 1, in: statement)
            bind(idempotencyDigest, to: 2, in: statement)
            bind(fingerprint, to: 3, in: statement)
            bind(timestamp, to: 4, in: statement)
            bind(timestamp, to: 5, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw unavailable() }
        }
    }

    private struct ResponseHead {
        let requestID: RequestID
        let status: MessageStatus
        let correlationStatus: SendCorrelationStatus
        let conversationID: ConversationID?
    }

    private func decodeResponseHead(_ statement: OpaquePointer) throws -> ResponseHead {
        let requestID = try RequestID(validating: requiredText(statement, index: 0))
        guard let status = MessageStatus(rawValue: try requiredText(statement, index: 1)) else {
            throw SendRequestStorageError.unavailable("The relay state database contains an invalid status.")
        }
        guard let correlationStatus = SendCorrelationStatus(
            rawValue: try requiredText(statement, index: 2)
        ) else {
            throw SendRequestStorageError.unavailable(
                "The relay state database contains an invalid correlation status."
            )
        }
        return ResponseHead(
            requestID: requestID,
            status: status,
            correlationStatus: correlationStatus,
            conversationID: try optionalText(statement, index: 3).map {
                try ConversationID(validating: $0)
            }
        )
    }

    private func response(from head: ResponseHead) throws -> SendMessageResponse {
        let messages = try withStatement("""
            SELECT message_id, last_status
            FROM send_request_message
            WHERE request_id = ?
            ORDER BY ordinal ASC
            """) { statement in
            bind(head.requestID.rawValue, to: 1, in: statement)
            var values: [MessageReceipt] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let messageID = try MessageID(validating: requiredText(statement, index: 0))
                    guard let status = MessageStatus(
                        rawValue: try requiredText(statement, index: 1)
                    ) else {
                        throw SendRequestStorageError.unavailable(
                            "The relay state database contains an invalid message receipt status."
                        )
                    }
                    values.append(MessageReceipt(messageID: messageID, status: status))
                case SQLITE_DONE: return values
                default: throw unavailable()
                }
            }
        }
        let media = try withStatement("""
            SELECT requested_media_id, media_id, message_id
            FROM send_request_media
            WHERE request_id = ?
            ORDER BY ordinal ASC
            """) { statement in
            bind(head.requestID.rawValue, to: 1, in: statement)
            var values: [MediaReceipt] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let requestedMediaID = try MediaID(
                        validating: requiredText(statement, index: 0)
                    )
                    let mediaID = try optionalText(statement, index: 1).map {
                        try MediaID(validating: $0)
                    }
                    let messageID = try optionalText(statement, index: 2).map {
                        try MessageID(validating: $0)
                    }
                    values.append(MediaReceipt(
                        requestedMediaID: requestedMediaID,
                        mediaID: mediaID,
                        messageID: messageID
                    ))
                case SQLITE_DONE: return values
                default: throw unavailable()
                }
            }
        }
        return .tracking(
            requestID: head.requestID,
            status: head.status,
            correlationStatus: head.correlationStatus,
            conversationID: head.conversationID,
            messages: messages,
            media: media
        )
    }

    private func replaceMessages(
        _ messages: [MessageReceipt],
        requestID: RequestID
    ) throws {
        try withStatement("DELETE FROM send_request_message WHERE request_id = ?") { statement in
            bind(requestID.rawValue, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw unavailable() }
        }
        for (ordinal, message) in messages.enumerated() {
            try withStatement("""
                INSERT INTO send_request_message (
                    request_id, message_id, ordinal, last_status
                ) VALUES (?, ?, ?, ?)
                """) { statement in
                bind(requestID.rawValue, to: 1, in: statement)
                bind(message.messageID.rawValue, to: 2, in: statement)
                sqlite3_bind_int64(statement, 3, Int64(ordinal))
                bind(message.status.rawValue, to: 4, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw unavailable() }
            }
        }
    }

    private func replaceMedia(
        _ media: [MediaReceipt],
        requestID: RequestID
    ) throws {
        try withStatement("DELETE FROM send_request_media WHERE request_id = ?") { statement in
            bind(requestID.rawValue, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw unavailable() }
        }
        for (ordinal, item) in media.enumerated() {
            try withStatement("""
                INSERT INTO send_request_media (
                    request_id, requested_media_id, ordinal, media_id, message_id
                ) VALUES (?, ?, ?, ?, ?)
                """) { statement in
                bind(requestID.rawValue, to: 1, in: statement)
                bind(item.requestedMediaID.rawValue, to: 2, in: statement)
                sqlite3_bind_int64(statement, 3, Int64(ordinal))
                bind(item.mediaID?.rawValue, to: 4, in: statement)
                bind(item.messageID?.rawValue, to: 5, in: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw unavailable() }
            }
        }
    }

    private func execute(_ sql: String) throws {
        try Self.execute(handle, sql)
    }

    private static func prepareDatabase(_ handle: OpaquePointer, at url: URL) throws {
        try execute(handle, "PRAGMA busy_timeout=5000")
        try execute(handle, "PRAGMA journal_mode=WAL")
        try execute(handle, """
            CREATE TABLE IF NOT EXISTS send_request (
                request_id TEXT PRIMARY KEY NOT NULL,
                idempotency_digest TEXT UNIQUE,
                fingerprint TEXT NOT NULL,
                status TEXT NOT NULL,
                correlation_status TEXT NOT NULL DEFAULT 'pending',
                conversation_id TEXT,
                message_id TEXT,
                correlation_json TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """)
        if !hasColumn(handle, table: "send_request", column: "correlation_json") {
            try execute(handle, "ALTER TABLE send_request ADD COLUMN correlation_json TEXT")
        }
        if !hasColumn(handle, table: "send_request", column: "correlation_status") {
            try execute(
                handle,
                "ALTER TABLE send_request ADD COLUMN correlation_status TEXT NOT NULL DEFAULT 'pending'"
            )
        }
        if !hasColumn(handle, table: "send_request", column: "conversation_id") {
            try execute(handle, "ALTER TABLE send_request ADD COLUMN conversation_id TEXT")
        }
        try execute(handle, """
            CREATE TABLE IF NOT EXISTS send_request_message (
                request_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                last_status TEXT NOT NULL,
                PRIMARY KEY (request_id, message_id)
            )
            """)
        try execute(handle, """
            CREATE TABLE IF NOT EXISTS send_request_media (
                request_id TEXT NOT NULL,
                requested_media_id TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                media_id TEXT,
                message_id TEXT,
                PRIMARY KEY (request_id, ordinal)
            )
            """)
        try execute(
            handle,
            "UPDATE send_request SET status = 'result_unknown' WHERE status = 'sending'"
        )
        try execute(handle, """
            INSERT OR IGNORE INTO send_request_message (
                request_id, message_id, ordinal, last_status
            )
            SELECT request_id, message_id, 0, status
            FROM send_request
            WHERE message_id IS NOT NULL
            """)
        try execute(handle, """
            UPDATE send_request
            SET correlation_status = CASE
                WHEN status = 'result_unknown' THEN 'ambiguous'
                WHEN message_id IS NOT NULL THEN 'complete'
                WHEN status IN ('failed', 'unsupported') THEN 'complete'
                ELSE correlation_status
            END
            """)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func execute(_ handle: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SendRequestStorageError.unavailable(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private static func hasColumn(
        _ handle: OpaquePointer,
        table: String,
        column: String
    ) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: name) == column { return true }
        }
        return false
    }

    private func withStatement<Value>(
        _ sql: String,
        _ body: (OpaquePointer) throws -> Value
    ) throws -> Value {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw unavailable() }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func requiredText(_ statement: OpaquePointer, index: Int32) throws -> String {
        guard let value = optionalText(statement, index: index) else {
            throw SendRequestStorageError.unavailable("The relay state database contains NULL unexpectedly.")
        }
        return value
    }

    private func optionalText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func unavailable() -> SendRequestStorageError {
        .unavailable(String(cString: sqlite3_errmsg(handle)))
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
