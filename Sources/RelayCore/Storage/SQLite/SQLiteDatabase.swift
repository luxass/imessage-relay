import CryptoKit
import Foundation
import SQLite3

let sqliteTransient = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)

public enum SQLiteStorageError: Error, CustomStringConvertible, Equatable, Sendable {
    case cannotOpen(String)
    case incompatibleSchema([String])
    case queryFailed(String)
    case corruptValue(column: String, detail: String)
    case invalidCursor
    case shutDown

    public var description: String {
        switch self {
        case .cannotOpen(let detail): "Cannot open Messages database: \(detail)"
        case .incompatibleSchema(let missing):
            "Messages database schema is missing: \(missing.joined(separator: ", "))"
        case .queryFailed(let detail): "Messages database query failed: \(detail)"
        case let .corruptValue(column, detail): "Invalid \(column): \(detail)"
        case .invalidCursor: "The cursor is invalid or does not match this query."
        case .shutDown: "The Messages database reader is shut down."
        }
    }
}

final class SQLiteDatabase {
    let path: String
    let schema: SchemaInspector
    let connectionFileIdentity: String

    private var handle: OpaquePointer?

    init(path: String) throws {
        self.path = path
        let identityBeforeOpen = try Self.pathFileIdentity(path)
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            path,
            &opened,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let detail = opened.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 returned \(result)"
            sqlite3_close(opened)
            throw SQLiteStorageError.cannotOpen(detail)
        }
        handle = opened
        do {
            let identityAfterOpen = try Self.pathFileIdentity(path)
            guard identityAfterOpen == identityBeforeOpen else {
                throw SQLiteStorageError.cannotOpen("Database changed while opening it.")
            }
            connectionFileIdentity = identityAfterOpen
            sqlite3_extended_result_codes(opened, 1)
            guard sqlite3_busy_timeout(opened, 5_000) == SQLITE_OK else {
                throw SQLiteStorageError.queryFailed(String(cString: sqlite3_errmsg(opened)))
            }
            guard sqlite3_exec(opened, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteStorageError.queryFailed(String(cString: sqlite3_errmsg(opened)))
            }
            let inspectedSchema = try SchemaInspector(database: opened)
            try inspectedSchema.validateRequiredShape()
            schema = inspectedSchema
        } catch {
            sqlite3_close(opened)
            handle = nil
            throw error
        }
    }

    deinit { sqlite3_close(handle) }

    func withStatement<Value>(_ sql: String, _ body: (SQLiteStatement) throws -> Value) throws -> Value {
        guard let handle else { throw SQLiteStorageError.shutDown }
        let statement = try SQLiteStatement(connection: handle, sql: sql)
        do {
            let value = try body(statement)
            if let cleanupError = statement.finalize() { throw cleanupError }
            return value
        } catch {
            _ = statement.finalize()
            throw error
        }
    }

    func execute(_ sql: String) throws {
        try withStatement(sql) { statement in
            try statement.expectDone()
        }
    }

    func withReadTransaction<Value>(_ body: () throws -> Value) throws -> Value {
        try execute("BEGIN DEFERRED TRANSACTION")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func identity() throws -> String {
        let fileIdentity = connectionFileIdentity
        let schemaText = try firstText("""
            SELECT COALESCE(group_concat(value, '|'), '') FROM (
                SELECT type || ':' || name || ':' || COALESCE(sql, '') AS value
                FROM sqlite_master
                WHERE name NOT LIKE 'sqlite_%'
                ORDER BY type, name
            )
            """) ?? ""
        let firstChat = try firstText("SELECT guid FROM chat ORDER BY ROWID LIMIT 1") ?? ""
        let firstMessage = try firstText("SELECT guid FROM message ORDER BY ROWID LIMIT 1") ?? ""
        let digest = SHA256.hash(data: Data("\(schemaText)\u{1f}\(firstChat)\u{1f}\(firstMessage)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "v1:\(fileIdentity);identity=\(digest.prefix(24))"
    }

    func fileIdentity() throws -> String {
        try Self.pathFileIdentity(path)
    }

    func isCurrentGeneration() throws -> Bool {
        try fileIdentity() == connectionFileIdentity
    }

    private static func pathFileIdentity(_ path: String) throws -> String {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            throw SQLiteStorageError.cannotOpen("Cannot inspect database file: \(error)")
        }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        guard let device, let inode else {
            throw SQLiteStorageError.queryFailed("Database filesystem identity is unavailable.")
        }
        return "device=\(device);inode=\(inode)"
    }

    func dataVersion() throws -> Int64 {
        try withStatement("PRAGMA data_version") { statement in
            guard try statement.step() == .row else {
                throw SQLiteStorageError.queryFailed("PRAGMA data_version returned no row.")
            }
            return try statement.int64(0)
        }
    }

    func firstText(_ sql: String) throws -> String? {
        try withStatement(sql) { statement in
            guard try statement.step() == .row else { return nil }
            return try statement.optionalText(0)
        }
    }
}

enum SQLiteValue {
    static func text(_ statement: SQLiteStatement, _ index: Int32) throws -> String {
        try statement.text(index)
    }

    static func optionalText(_ statement: SQLiteStatement, _ index: Int32) throws -> String? {
        try statement.optionalText(index)
    }

    static func optionalInt64(_ statement: SQLiteStatement, _ index: Int32) throws -> Int64? {
        try statement.optionalInt64(index)
    }

    static func optionalData(_ statement: SQLiteStatement, _ index: Int32) throws -> Data? {
        try statement.optionalData(index)
    }
}
