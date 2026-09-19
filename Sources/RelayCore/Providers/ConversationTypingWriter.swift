public struct ConversationTypingWriteRequest: Equatable, Sendable {
    public let conversationGUID: String
    public let anchorMessageGUID: String
    public let isGroup: Bool

    public init(conversationGUID: String, anchorMessageGUID: String, isGroup: Bool) {
        self.conversationGUID = conversationGUID
        self.anchorMessageGUID = anchorMessageGUID
        self.isGroup = isGroup
    }
}

public enum ConversationTypingWriterError: Error, Equatable, Sendable {
    case draftConflict(String)
    case unsupported(String)
    case unavailable(String)
    case notStarted(String)
    case uncertain(String)
}

public protocol ConversationTypingWriting: Sendable {
    func startTyping(_ request: ConversationTypingWriteRequest) async throws
    func stopTyping(_ request: ConversationTypingWriteRequest) async throws
}

public protocol TypingLeaseStopping: Sendable {
    func stopActiveTyping() async throws
}
