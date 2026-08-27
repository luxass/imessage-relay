/// Resumable catch-up page. `nextRowid` is the physical scan cursor and may be
/// greater than the last returned message's rowid (suppressed rows advance it).
public struct MessagesPage: Codable, Sendable {
    public var messages: [Message]
    public var nextRowid: Int64
    public var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case messages
        case nextRowid = "next_rowid"
        case hasMore = "has_more"
    }

    public init(messages: [Message], nextRowid: Int64, hasMore: Bool) {
        self.messages = messages
        self.nextRowid = nextRowid
        self.hasMore = hasMore
    }
}
