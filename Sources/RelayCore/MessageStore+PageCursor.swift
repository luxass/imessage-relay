import CryptoKit
import Foundation
import SQLite3

enum PageDate: Codable {
    case integer(Int64)
    case real(Double)

    private enum CodingKeys: String, CodingKey {
        case storage
        case value
    }

    private enum Storage: String, Codable {
        case integer
        case real
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Storage.self, forKey: .storage) {
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .value))
        case .real:
            self = .real(try container.decode(Double.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .integer(value):
            try container.encode(Storage.integer, forKey: .storage)
            try container.encode(value, forKey: .value)
        case let .real(value):
            try container.encode(Storage.real, forKey: .storage)
            try container.encode(value, forKey: .value)
        }
    }

    var doubleValue: Double {
        switch self {
        case let .integer(value): Double(value)
        case let .real(value): value
        }
    }

    func bind(to statement: OpaquePointer, at index: Int32) {
        switch self {
        case let .integer(value): sqlite3_bind_int64(statement, index, value)
        case let .real(value): sqlite3_bind_double(statement, index, value)
        }
    }

    static func read(from statement: OpaquePointer, at index: Int32) -> PageDate? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: nil
        case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, index))
        default: .real(sqlite3_column_double(statement, index))
        }
    }
}

extension SQLiteMessageStore {
    struct PageCursor: Codable {
        let version: Int
        let kind: String
        let fingerprint: String
        let signature: String?
        let date: PageDate?
        let rowid: Int64
    }

    func decodePageCursor(
        _ encoded: String?,
        kind: String,
        signature: String? = nil
    ) throws -> PageCursor? {
        guard let encoded else { return nil }
        var base64 = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let cursor = try? JSONDecoder().decode(PageCursor.self, from: data),
              cursor.version == 2,
              cursor.kind == kind,
              cursor.fingerprint == fingerprint(),
              cursor.signature == signature,
              cursor.rowid > 0 else {
            throw StoreError.invalidCursor
        }
        return cursor
    }

    func encodePageCursor(
        kind: String,
        signature: String? = nil,
        date: PageDate?,
        rowid: Int64
    ) throws -> String {
        let cursor = PageCursor(
            version: 2,
            kind: kind,
            fingerprint: fingerprint(),
            signature: signature,
            date: date,
            rowid: rowid
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(cursor).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    func messageHistorySignature(
        chatID: Int64,
        includeAttachments: Bool,
        includeReactions: Bool,
        query: String?,
        exactMatch: Bool
    ) -> String {
        let queryValue = query.map { "some\u{0}\($0)" } ?? "none"
        let value = "v2\u{0}\(chatID)\u{0}\(includeAttachments)\u{0}\(includeReactions)\u{0}\(exactMatch)\u{0}\(queryValue)"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
