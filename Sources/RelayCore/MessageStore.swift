import Foundation
import NIOPosix
import SQLite3

/// Read-only access to the macOS Messages database (`chat.db`).
public final class MessageStore: Sendable {
    public enum StoreError: Error, CustomStringConvertible {
        case cannotOpen(String)
        case invalidCursor
        case queryFailed(String)
        case shutDown

        public var description: String {
            switch self {
            case .cannotOpen(let detail):
                return "Cannot open Messages database: \(detail)"
            case .invalidCursor:
                return "Invalid or expired page cursor"
            case .queryFailed(let detail):
                return "Messages database query failed: \(detail)"
            case .shutDown:
                return "Messages database store is shut down"
            }
        }
    }

    private final class StorageBox: @unchecked Sendable {
        var store: SQLiteMessageStore?
    }

    private final class Lifecycle: @unchecked Sendable {
        private let lock = NSLock()
        private var cleanupTask: Task<Void, Error>?

        func ensureActive() throws {
            try lock.withLock {
                guard cleanupTask == nil else { throw StoreError.shutDown }
            }
        }

        func beginCleanup(storage: StorageBox, threadPool: NIOThreadPool) -> Task<Void, Error> {
            lock.withLock {
                if let cleanupTask { return cleanupTask }
                let task = Task.detached {
                    var releaseError: (any Error)?
                    do {
                        try await threadPool.runIfActive {
                            storage.store = nil
                        }
                    } catch {
                        releaseError = error
                    }
                    try await threadPool.shutdownGracefully()
                    if let releaseError { throw releaseError }
                }
                cleanupTask = task
                return task
            }
        }
    }

    public let path: String

    private let threadPool: NIOThreadPool
    private let storage = StorageBox()
    private let lifecycle = Lifecycle()

    public init(path: String) {
        self.path = path
        threadPool = NIOThreadPool(numberOfThreads: 1)
        threadPool.start()
    }

    deinit {
        _ = lifecycle.beginCleanup(storage: storage, threadPool: threadPool)
    }

    public func chats(
        limit: Int = 20,
        unreadOnly: Bool = false,
        cursor: String? = nil
    ) async throws -> Page<Chat> {
        try await run { try $0.chats(limit: limit, unreadOnly: unreadOnly, cursor: cursor) }
    }

    public func chat(id: Int64) async throws -> Chat? {
        try await run { try $0.chat(id: id) }
    }

    public func messages(
        chatID: Int64,
        limit: Int = 50,
        cursor: String? = nil,
        includeAttachments: Bool = false,
        includeReactions: Bool = false,
        query: String? = nil,
        exactMatch: Bool = false
    ) async throws -> Page<Message> {
        try await run {
            try $0.messages(
                chatID: chatID,
                limit: limit,
                cursor: cursor,
                includeAttachments: includeAttachments,
                includeReactions: includeReactions,
                query: query,
                exactMatch: exactMatch
            )
        }
    }

    public func sendTarget(chatID: Int64) async throws -> ChatSendTarget? {
        try await run { try $0.sendTarget(chatID: chatID) }
    }

    public func attachmentResource(rowid: Int64) async throws -> AttachmentResource? {
        let threadPool = threadPool
        return try await run { try $0.attachmentResource(rowid: rowid, threadPool: threadPool) }
    }

    @available(*, deprecated, message: "Use attachmentResource(rowid:) to avoid buffering attachment files")
    public func attachmentData(rowid: Int64) async throws -> AttachmentFile? {
        guard let resource = try await attachmentResource(rowid: rowid) else { return nil }
        var data = Data()
        var offset: Int64 = 0
        while offset < resource.byteCount {
            let chunk = try await resource.readChunk(atOffset: offset, upToCount: 128 * 1024)
            guard !chunk.isEmpty else { break }
            data.append(chunk)
            offset += Int64(chunk.count)
        }
        return AttachmentFile(data: data, mimeType: resource.mimeType)
    }

    public func status() async -> DatabaseStatus {
        do {
            return try await run { $0.status() }
        } catch {
            return .init(
                ready: false,
                path: path,
                fingerprint: "",
                error: "\(error). Grant Full Disk Access to the process running this server."
            )
        }
    }

    public func shutdown() async throws {
        try await lifecycle.beginCleanup(storage: storage, threadPool: threadPool).value
    }

    private func run<Value: Sendable>(
        _ operation: @escaping @Sendable (SQLiteMessageStore) throws -> Value
    ) async throws -> Value {
        let path = path
        let storage = storage
        let lifecycle = lifecycle
        try lifecycle.ensureActive()
        return try await threadPool.runIfActive {
            try lifecycle.ensureActive()
            let store: SQLiteMessageStore
            if let existing = storage.store {
                store = existing
            } else {
                let opened = try SQLiteMessageStore(path: path)
                storage.store = opened
                store = opened
            }
            return try operation(store)
        }
    }
}

/// Synchronous SQLite state confined to `MessageStore`'s dedicated thread.
final class SQLiteMessageStore {
    typealias StoreError = MessageStore.StoreError

    let path: String
    let connection: SQLiteReadConnection
    let schema: MessageStoreSchema

    private static let isoFormat = Date.ISO8601FormatStyle(timeZone: .gmt)

    init(path: String) throws {
        let connection = try SQLiteReadConnection(path: path)
        self.path = path
        self.connection = connection
        schema = try MessageStoreSchema(connection: connection)
    }

    func status() -> DatabaseStatus {
        var ready = false
        var failure: String?
        do {
            _ = try connection.firstInt64("SELECT count(*) FROM chat LIMIT 1")
            ready = true
        } catch {
            failure = String(describing: error)
        }
        return DatabaseStatus(ready: ready, path: path, fingerprint: fingerprint(), error: failure)
    }

    func fingerprint() -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            return "v3:unavailable"
        }
        // SQLite has no immutable database UUID. Schema and the oldest durable
        // row anchors distinguish an in-place reset without tracking mutations.
        let identity = (try? connection.firstText("""
            SELECT COALESCE(group_concat(value, '|'), '') FROM (
                SELECT type || ':' || name || ':' || COALESCE(sql, '') AS value
                  FROM sqlite_master
                 WHERE name NOT LIKE 'sqlite_%'
                 ORDER BY type, name
            )
            """)) ?? ""
        let chatAnchor = (try? connection.firstText(
            "SELECT COALESCE(guid, '') FROM chat ORDER BY ROWID LIMIT 1"
        )) ?? ""
        let messageAnchor = (try? connection.firstText(
            "SELECT COALESCE(guid, '') FROM message ORDER BY ROWID LIMIT 1"
        )) ?? ""
        let digest = Self.fnv1a64("\(identity)\u{1f}\(chatAnchor)\u{1f}\(messageAnchor)")
        return "v3:device=\(device.uint64Value);inode=\(inode.uint64Value);identity=\(String(digest, radix: 16))"
    }

    private static func fnv1a64(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    static func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }

    static func optionalDateText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return dateText(sqlite3_column_double(statement, index))
    }

    static func dateText(_ raw: Double?) -> String? {
        guard let raw else { return nil }
        guard raw > 0 else { return nil }
        let seconds = abs(raw) > 10_000_000_000 ? raw / 1_000_000_000 : raw
        return Date(timeIntervalSinceReferenceDate: seconds).formatted(isoFormat)
    }

    static func clampLimit(_ value: Int, max maximum: Int = 200) -> Int {
        Swift.max(1, Swift.min(value, maximum))
    }
}
