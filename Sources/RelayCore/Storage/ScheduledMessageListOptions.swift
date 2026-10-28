public struct ScheduledMessageListOptions: Equatable, Sendable {
    public let limit: Int
    public let cursor: Cursor?
    public let includeAttachments: Bool

    public init(limit: Int = 50, cursor: Cursor? = nil, includeAttachments: Bool = false) {
        self.limit = limit
        self.cursor = cursor
        self.includeAttachments = includeAttachments
    }
}
