public struct PaginatedResponse<Element: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let items: [Element]
    public let nextCursor: Cursor?
    public let hasMore: Bool

    private enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }

    public init(items: [Element], nextCursor: Cursor?, hasMore: Bool) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}
