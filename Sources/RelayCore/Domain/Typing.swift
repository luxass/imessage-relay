public enum ConversationTypingStatus: String, Codable, Equatable, Sendable {
    case active
    case inactive
}

public struct ConversationTypingResponse: Codable, Equatable, Sendable {
    public let requestID: RequestID
    public let conversationID: ConversationID
    public let status: ConversationTypingStatus
    public let expiresAt: Timestamp?

    private enum CodingKeys: String, CodingKey {
        case status
        case requestID = "request_id"
        case conversationID = "conversation_id"
        case expiresAt = "expires_at"
    }

    public init(
        requestID: RequestID,
        conversationID: ConversationID,
        status: ConversationTypingStatus,
        expiresAt: Timestamp?
    ) {
        self.requestID = requestID
        self.conversationID = conversationID
        self.status = status
        self.expiresAt = expiresAt
    }
}
