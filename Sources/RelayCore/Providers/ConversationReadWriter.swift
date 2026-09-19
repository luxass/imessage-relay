public struct ConversationReadWriteRequest: Equatable, Sendable {
    public let conversationGUID: String
    public let anchorMessageGUID: String

    public init(conversationGUID: String, anchorMessageGUID: String) {
        self.conversationGUID = conversationGUID
        self.anchorMessageGUID = anchorMessageGUID
    }
}

public enum ConversationReadWriterError: Error, Equatable, Sendable {
    case unsupported(String)
    case unavailable(String)
    case notStarted(String)
    case uncertain(String)
}

public protocol ConversationReadWriting: Sendable {
    func markRead(_ request: ConversationReadWriteRequest) async throws
}
