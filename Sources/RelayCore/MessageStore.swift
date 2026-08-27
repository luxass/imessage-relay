import Foundation
import SQLite3

/// Read-only access to the macOS Messages database (`chat.db`).
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

    public let path: String
    let connection: SQLiteReadConnection
    let schema: MessageStoreSchema

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    public init(path: String) throws {
        let connection = try SQLiteReadConnection(path: path)
        self.path = path
        self.connection = connection
        schema = try MessageStoreSchema(connection: connection)
    }

    public func status() -> DatabaseStatus {
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

    private func fingerprint() -> String {
        let pageCount = (try? connection.firstInt64("PRAGMA page_count")) ?? -1
        let userVersion = (try? connection.firstInt64("PRAGMA user_version")) ?? -1
        var size: UInt64 = 0
        var mtime: Double = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
        return "pages=\(pageCount);uv=\(userVersion);size=\(size);mtime=\(mtime)"
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
        let raw = sqlite3_column_double(statement, index)
        guard raw > 0 else { return nil }
        let seconds = abs(raw) > 10_000_000_000 ? raw / 1_000_000_000 : raw
        return isoFormatter.string(from: Date(timeIntervalSinceReferenceDate: seconds))
    }

    static func clampLimit(_ value: Int, max maximum: Int = 200) -> Int {
        Swift.max(1, Swift.min(value, maximum))
    }
}
