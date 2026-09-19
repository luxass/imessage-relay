public struct Conversation: Codable, Equatable, Sendable {
    public let id: ConversationID
    public let providerGUID: String?
    public let identifier: String?
    public let displayName: String?
    public let service: String?
    public let isGroup: Bool
    public let participants: [RecipientHandle]
    public let unreadCount: Int
    public let lastMessageAt: Timestamp?

    private enum CodingKeys: String, CodingKey {
        case id
        case providerGUID = "provider_guid"
        case identifier
        case displayName = "display_name"
        case service
        case isGroup = "is_group"
        case participants
        case unreadCount = "unread_count"
        case lastMessageAt = "last_message_at"
    }

    public init(
        id: ConversationID,
        providerGUID: String?,
        identifier: String?,
        displayName: String?,
        service: String?,
        isGroup: Bool,
        participants: [RecipientHandle],
        unreadCount: Int,
        lastMessageAt: Timestamp?
    ) {
        self.id = id
        self.providerGUID = providerGUID
        self.identifier = identifier
        self.displayName = displayName
        self.service = service
        self.isGroup = isGroup
        self.participants = participants
        self.unreadCount = unreadCount
        self.lastMessageAt = lastMessageAt
    }
}

public struct ConversationSendContext: Equatable, Sendable {
    public let conversationID: ConversationID
    public let providerGUID: String
    public let accountID: String?
    public let accountLogin: String?
    public let recipients: [RecipientHandle]

    public init(
        conversationID: ConversationID,
        providerGUID: String,
        accountID: String?,
        accountLogin: String?,
        recipients: [RecipientHandle]
    ) {
        self.conversationID = conversationID
        self.providerGUID = providerGUID
        self.accountID = accountID
        self.accountLogin = accountLogin
        self.recipients = recipients
    }
}

public enum ConversationReadStatus: String, Codable, Equatable, Sendable {
    case applied
    case unchanged
}

public struct ConversationReadResponse: Codable, Equatable, Sendable {
    public let requestID: RequestID
    public let conversationID: ConversationID
    public let status: ConversationReadStatus

    private enum CodingKeys: String, CodingKey {
        case status
        case requestID = "request_id"
        case conversationID = "conversation_id"
    }

    public init(
        requestID: RequestID,
        conversationID: ConversationID,
        status: ConversationReadStatus
    ) {
        self.requestID = requestID
        self.conversationID = conversationID
        self.status = status
    }
}
