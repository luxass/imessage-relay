import Foundation

public struct OutboundMedia: Equatable, Sendable {
    public let reference: MediaReference
    public let fileURL: URL

    public init(reference: MediaReference, fileURL: URL) {
        self.reference = reference
        self.fileURL = fileURL
    }
}

public struct ReplySendContext: Equatable, Sendable {
    public let messageID: MessageID
    public let threadOriginatorMessageID: MessageID?

    public init(
        messageID: MessageID,
        threadOriginatorMessageID: MessageID?
    ) {
        self.messageID = messageID
        self.threadOriginatorMessageID = threadOriginatorMessageID
    }
}

public struct SenderDispatchRequest: Equatable, Sendable {
    public let requestID: RequestID
    public let destination: MessageDestination
    public let conversationContext: ConversationSendContext?
    public let conversationAnchorMessageID: MessageID?
    public let text: String?
    public let media: [OutboundMedia]
    public let replyTarget: ReplyTarget?
    public let replyContext: ReplySendContext?

    public init(
        requestID: RequestID,
        destination: MessageDestination,
        conversationContext: ConversationSendContext?,
        conversationAnchorMessageID: MessageID? = nil,
        text: String?,
        media: [OutboundMedia],
        replyTarget: ReplyTarget?,
        replyContext: ReplySendContext? = nil
    ) {
        self.requestID = requestID
        self.destination = destination
        self.conversationContext = conversationContext
        self.conversationAnchorMessageID = conversationAnchorMessageID
        self.text = text
        self.media = media
        self.replyTarget = replyTarget
        self.replyContext = replyContext
    }
}

public struct SenderDispatchResult: Equatable, Sendable {
    public let messageID: MessageID?
    public let status: MessageStatus

    public init(messageID: MessageID?, status: MessageStatus) {
        self.messageID = messageID
        self.status = status
    }
}

public enum MessageSenderError: Error, Equatable, Sendable {
    case unsupported(String)
    case unavailable(String)
    case notStarted(String)
    case uncertain(String)
}

public protocol MessageSender: Sendable {
    func status() async -> Sender
    func send(_ request: SenderDispatchRequest) async throws -> SenderDispatchResult
}
