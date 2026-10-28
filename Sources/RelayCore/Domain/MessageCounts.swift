import HummingbirdOpenAPIModels

public struct MessageCountRange: Equatable, Sendable {
    public let from: Timestamp
    public let to: Timestamp

    public init(from: Timestamp, to: Timestamp) throws {
        guard from.date < to.date else {
            throw RelayServiceError.invalidRequest([APIFieldError(field: "to", message: "to must be later than from.")])
        }
        self.from = from
        self.to = to
    }
}

@OpenAPISchema
public struct MessageCounts: Codable, Equatable, Sendable {
    public let conversationID: ConversationID
    public let from: Timestamp
    public let to: Timestamp
    public let sent: Int
    public let received: Int

    private enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
        case from, to, sent, received
    }

    public init(conversationID: ConversationID, range: MessageCountRange, sent: Int, received: Int) {
        self.conversationID = conversationID
        self.from = range.from
        self.to = range.to
        self.sent = sent
        self.received = received
    }
}
