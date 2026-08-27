public struct Page<Element: Codable & Sendable>: Codable, Sendable {
    public var items: [Element]
    public var nextCursor: String?
    public var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    public init(items: [Element], nextCursor: String?, hasMore: Bool) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(nextCursor, forKey: .nextCursor)
        try container.encode(hasMore, forKey: .hasMore)
    }
}
