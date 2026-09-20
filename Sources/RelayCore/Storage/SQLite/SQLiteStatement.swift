import Foundation
import SQLite3

final class SQLiteStatement {
    enum Step {
        case row
        case done
    }

    private let connection: OpaquePointer
    private var statement: OpaquePointer?
    private var boundParameters: Set<Int32> = []
    private var validatedBindings = false

    init(connection: OpaquePointer, sql: String) throws {
        self.connection = connection
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &prepared, nil)
        guard result == SQLITE_OK, let prepared else {
            sqlite3_finalize(prepared)
            throw Self.error(connection: connection, result: result, operation: "prepare")
        }
        statement = prepared
    }

    deinit {
        if let statement {
            sqlite3_finalize(statement)
        }
    }

    var parameterCount: Int32 {
        guard let statement else { return 0 }
        return sqlite3_bind_parameter_count(statement)
    }

    var columnCount: Int32 {
        guard let statement else { return 0 }
        return sqlite3_column_count(statement)
    }

    func bind(_ value: String, at index: Int32) throws {
        try bind(Optional(value), at: index)
    }

    func bind(_ value: String?, at index: Int32) throws {
        let statement = try openStatement()
        try validateParameter(index)
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        try checkBinding(result, index: index)
    }

    func bind(_ value: Int64, at index: Int32) throws {
        let statement = try openStatement()
        try validateParameter(index)
        try checkBinding(sqlite3_bind_int64(statement, index, value), index: index)
    }

    func bind(_ value: Double, at index: Int32) throws {
        let statement = try openStatement()
        try validateParameter(index)
        try checkBinding(sqlite3_bind_double(statement, index, value), index: index)
    }

    func step() throws -> Step {
        let statement = try openStatement()
        if !validatedBindings {
            let expected = Int(parameterCount)
            guard boundParameters.count == expected else {
                throw SQLiteStorageError.queryFailed(
                    "SQLite statement expected \(expected) bound parameters but received \(boundParameters.count)."
                )
            }
            validatedBindings = true
        }
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return .row
        case SQLITE_DONE: return .done
        default: throw Self.error(connection: connection, result: result, operation: "step")
        }
    }

    func expectDone() throws {
        guard try step() == .done else {
            throw SQLiteStorageError.queryFailed("SQLite statement unexpectedly returned a row.")
        }
    }

    func status(_ operation: Int32, reset: Bool = false) throws -> Int32 {
        sqlite3_stmt_status(try openStatement(), operation, reset ? 1 : 0)
    }

    func text(_ index: Int32) throws -> String {
        guard let value = try optionalText(index) else {
            throw SQLiteStorageError.corruptValue(
                column: columnName(index),
                detail: "expected text, found NULL"
            )
        }
        return value
    }

    func optionalText(_ index: Int32) throws -> String? {
        let statement = try columnStatement(index)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let bytes = sqlite3_column_text(statement, index) else {
            throw SQLiteStorageError.corruptValue(
                column: columnName(index),
                detail: "text conversion failed"
            )
        }
        return String(cString: bytes)
    }

    func int64(_ index: Int32) throws -> Int64 {
        let statement = try columnStatement(index)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            throw SQLiteStorageError.corruptValue(
                column: columnName(index),
                detail: "expected integer, found NULL"
            )
        }
        return sqlite3_column_int64(statement, index)
    }

    func optionalInt64(_ index: Int32) throws -> Int64? {
        let statement = try columnStatement(index)
        return sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : sqlite3_column_int64(statement, index)
    }

    func optionalData(_ index: Int32) throws -> Data? {
        let statement = try columnStatement(index)
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else {
            throw SQLiteStorageError.corruptValue(
                column: columnName(index),
                detail: "blob conversion failed"
            )
        }
        return Data(bytes: bytes, count: count)
    }

    func number(_ index: Int32) throws -> SQLiteNumber? {
        let statement = try columnStatement(index)
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: return nil
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        default: return .real(sqlite3_column_double(statement, index))
        }
    }

    func finalize() -> SQLiteStorageError? {
        guard let statement else { return nil }
        self.statement = nil
        let result = sqlite3_finalize(statement)
        guard result != SQLITE_OK else { return nil }
        return Self.error(connection: connection, result: result, operation: "finalize")
    }

    private func validateParameter(_ index: Int32) throws {
        guard index > 0, index <= parameterCount else {
            throw SQLiteStorageError.queryFailed(
                "SQLite parameter \(index) is outside 1...\(parameterCount)."
            )
        }
    }

    private func checkBinding(_ result: Int32, index: Int32) throws {
        guard result == SQLITE_OK else {
            throw Self.error(connection: connection, result: result, operation: "bind parameter \(index)")
        }
        boundParameters.insert(index)
        validatedBindings = false
    }

    private func openStatement() throws -> OpaquePointer {
        guard let statement else {
            throw SQLiteStorageError.queryFailed("SQLite statement is already finalized.")
        }
        return statement
    }

    private func columnStatement(_ index: Int32) throws -> OpaquePointer {
        let statement = try openStatement()
        guard index >= 0, index < columnCount else {
            throw SQLiteStorageError.corruptValue(
                column: "column \(index)",
                detail: "index is outside 0..<\(columnCount)"
            )
        }
        return statement
    }

    private func columnName(_ index: Int32) -> String {
        guard let statement,
              index >= 0,
              index < columnCount,
              let name = sqlite3_column_name(statement, index) else {
            return "column \(index)"
        }
        return String(cString: name)
    }

    private static func error(
        connection: OpaquePointer,
        result: Int32,
        operation: String
    ) -> SQLiteStorageError {
        let primary = result & 0xff
        let extended = sqlite3_extended_errcode(connection)
        let detail = "\(operation) failed with SQLite code \(result), extended code \(extended): "
            + String(cString: sqlite3_errmsg(connection))
        let category = primary == SQLITE_BUSY || primary == SQLITE_LOCKED ? "busy: " : ""
        return .queryFailed(category + detail)
    }
}
