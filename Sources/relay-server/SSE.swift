import Foundation
import RelayCore

/// Server-Sent Events wire format for `/messages/stream`.
///
/// Kept separate from the poll loop so the framing and cursor rules are pure
/// functions and unit-testable without Hummingbird or SQLite. Messages are
/// encoded with `JSONEncoder` against the same model codable the REST routes
/// use, so key conventions (snake_case, omit-nil) match exactly.
enum SSE {
    /// Comment frame sent after long silences so proxies don't kill the
    /// connection.
    static let keepalive = ": keepalive\n\n"

    /// Emitted once on connect so clients can log their effective cursor.
    static func ready(nextRowid: Int64) -> String {
        "event: ready\ndata: {\"next_rowid\": \(nextRowid)}\n\n"
    }

    /// One message as an SSE event. Fresh encoder per call — JSONEncoder is
    /// not documented thread-safe and streams may run concurrently.
    static func message(_ message: Message) throws -> String {
        let data = try JSONEncoder().encode(message)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                message,
                EncodingError.Context(codingPath: [], debugDescription: "message JSON was not valid UTF-8")
            )
        }
        return "event: message\ndata: \(json)\n\n"
    }

    /// Advances a scan cursor from a catch-up page. Defensive max: the cursor
    /// never regresses, mirroring the resumable-cursor invariant of
    /// `/messages/after` (scan position may sit past suppressed rows).
    static func advance(_ cursor: Int64, pageNextRowid nextRowid: Int64) -> Int64 {
        max(cursor, nextRowid)
    }
}
