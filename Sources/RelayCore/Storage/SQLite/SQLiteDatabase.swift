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

    private var handle: OpaquePointer?

    init(path: String) throws {
        self.path = path
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

    func withStatement<Value>(_ sql: String, _ body: (OpaquePointer) throws -> Value) throws -> Value {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteStorageError.queryFailed(lastError())
        }
        defer { sqlite3_finalize(statement) }
        do {
            return try body(statement)
        } catch let error as SQLiteStorageError {
            throw error
        } catch {
            throw SQLiteStorageError.queryFailed(String(describing: error))
        }
    }

    func execute(_ sql: String) throws {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteStorageError.queryFailed(lastError())
            }
        }
    }

    func identity() throws -> String {
        let fileIdentity = try fileIdentity()
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
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        guard let device, let inode else {
            throw SQLiteStorageError.queryFailed("Database filesystem identity is unavailable.")
        }
        return "device=\(device);inode=\(inode)"
    }

    func dataVersion() throws -> Int64 {
        try withStatement("PRAGMA data_version") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw SQLiteStorageError.queryFailed(lastError())
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func firstText(_ sql: String) throws -> String? {
        try withStatement(sql) { statement in
            switch sqlite3_step(statement) {
            case SQLITE_ROW: SQLiteValue.optionalText(statement, 0)
            case SQLITE_DONE: nil
            default: throw SQLiteStorageError.queryFailed(lastError())
            }
        }
    }

    func lastError() -> String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "No SQLite connection."
    }
}

enum SQLiteValue {
    static func text(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard let value = optionalText(statement, index) else {
            throw SQLiteStorageError.corruptValue(column: "column \(index)", detail: "expected text, found NULL")
        }
        return value
    }

    static func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: bytes)
    }

    static func optionalInt64(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, index)
    }

    static func optionalData(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}
