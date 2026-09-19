import CryptoKit
import Foundation
import SQLite3

enum SQLiteNumber: Codable, Equatable, Sendable {
    case integer(Int64)
    case real(Double)

    private enum CodingKeys: String, CodingKey { case storage, value }
    private enum Storage: String, Codable { case integer, real }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Storage.self, forKey: .storage) {
        case .integer: self = .integer(try container.decode(Int64.self, forKey: .value))
        case .real: self = .real(try container.decode(Double.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .integer(let value):
            try container.encode(Storage.integer, forKey: .storage)
            try container.encode(value, forKey: .value)
        case .real(let value):
            try container.encode(Storage.real, forKey: .storage)
            try container.encode(value, forKey: .value)
        }
    }

    func bind(to statement: OpaquePointer, at index: Int32) {
        switch self {
        case .integer(let value): sqlite3_bind_int64(statement, index, value)
        case .real(let value): sqlite3_bind_double(statement, index, value)
        }
    }

    var doubleValue: Double {
        switch self {
        case .integer(let value): Double(value)
        case .real(let value): value
        }
    }

    static func read(_ statement: OpaquePointer, _ index: Int32) -> Self? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: nil
        case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, index))
        default: .real(sqlite3_column_double(statement, index))
        }
    }
}

struct StorageCursor: Codable, Sendable {
    let version: Int
    let route: String
    let databaseIdentity: String
    let querySignature: String
    let date: SQLiteNumber?
    let rowID: Int64
}

enum CursorCodec {
    static func decode(
        _ cursor: Cursor?,
        route: String,
        databaseIdentity: String,
        querySignature: String
    ) throws -> StorageCursor? {
        guard let cursor else { return nil }
        var base64 = cursor.rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(StorageCursor.self, from: data),
              payload.version == 1,
              payload.route == route,
              payload.databaseIdentity == databaseIdentity,
              payload.querySignature == querySignature,
              payload.rowID > 0 else {
            throw SQLiteStorageError.invalidCursor
        }
        return payload
    }

    static func encode(
        route: String,
        databaseIdentity: String,
        querySignature: String,
        date: SQLiteNumber?,
        rowID: Int64
    ) throws -> Cursor {
        let payload = StorageCursor(
            version: 1,
            route: route,
            databaseIdentity: databaseIdentity,
            querySignature: querySignature,
            date: date,
            rowID: rowID
        )
        let data = try RelayJSON.encoder.encode(payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try Cursor(validating: encoded)
    }

    static func signature(_ components: [String]) -> String {
        SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
