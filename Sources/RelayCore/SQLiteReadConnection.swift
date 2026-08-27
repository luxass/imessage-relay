import Foundation
import SQLite3

/// SQLite's SQLITE_TRANSIENT is not exposed to Swift.
let sqliteTransient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

/// Owns a read-only SQLite handle serialized by SQLite's FULLMUTEX mode.
final class SQLiteReadConnection: @unchecked Sendable {
    private var database: OpaquePointer?

    init(path: String) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 returned \(result)"
            sqlite3_close(handle)
            throw MessageStore.StoreError.cannotOpen(detail)
        }
        database = handle
    }

    deinit {
        sqlite3_close(database)
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MessageStore.StoreError.queryFailed(lastError())
        }
        defer { sqlite3_finalize(statement) }

        do {
            return try body(statement)
        } catch let error as MessageStore.StoreError {
            throw error
        } catch {
            throw MessageStore.StoreError.queryFailed(String(describing: error))
        }
    }

    func firstInt64(_ sql: String) throws -> Int64 {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw MessageStore.StoreError.queryFailed(lastError())
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func firstText(_ sql: String) throws -> String {
        try withStatement(sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw MessageStore.StoreError.queryFailed(lastError())
            }
            return SQLiteMessageStore.text(statement, 0)
        }
    }

    func queryPlan(
        for sql: String,
        bind: (OpaquePointer) -> Void = { _ in }
    ) throws -> [String] {
        try withStatement("EXPLAIN QUERY PLAN \(sql)") { statement in
            bind(statement)
            var details: [String] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    details.append(SQLiteMessageStore.text(statement, 3))
                case SQLITE_DONE:
                    return details
                default:
                    throw MessageStore.StoreError.queryFailed(lastError())
                }
            }
        }
    }

    func lastError() -> String {
        guard let database else { return "no connection" }
        return String(cString: sqlite3_errmsg(database))
    }
}
