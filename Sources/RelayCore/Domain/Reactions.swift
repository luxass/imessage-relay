import Foundation

public enum WritableReaction: String, Codable, Equatable, Sendable {
    case love
    case like
    case dislike
    case laugh
    case emphasis
    case question
}

public struct SetReactionRequest: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidReaction
    }

    public let reaction: WritableReaction

    private enum CodingKeys: String, CodingKey {
        case reaction
    }

    public init(reaction: WritableReaction) {
        self.reaction = reaction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(String.self, forKey: .reaction)
        guard let reaction = WritableReaction(rawValue: rawValue) else {
            throw ValidationError.invalidReaction
        }
        self.reaction = reaction
    }
}

public enum ReactionWriteStatus: String, Codable, Equatable, Sendable {
    case applied
    case unchanged
}

public struct ReactionWriteResponse: Codable, Equatable, Sendable {
    public let requestID: RequestID
    public let status: ReactionWriteStatus
    public let messageID: MessageID
    public let reaction: WritableReaction?

    private enum CodingKeys: String, CodingKey {
        case status, reaction
        case requestID = "request_id"
        case messageID = "message_id"
    }

    public init(
        requestID: RequestID,
        status: ReactionWriteStatus,
        messageID: MessageID,
        reaction: WritableReaction?
    ) {
        self.requestID = requestID
        self.status = status
        self.messageID = messageID
        self.reaction = reaction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(RequestID.self, forKey: .requestID)
        status = try container.decode(ReactionWriteStatus.self, forKey: .status)
        messageID = try container.decode(MessageID.self, forKey: .messageID)
        reaction = try container.decodeIfPresent(WritableReaction.self, forKey: .reaction)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(status, forKey: .status)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(reaction, forKey: .reaction)
    }
}

public struct ReactionDispatchRequest: Equatable, Sendable {
    public let conversationGUID: String
    public let messageGUID: String
    public let useOverlay: Bool
    public let reaction: WritableReaction
    public let enabled: Bool

    public init(
        conversationGUID: String,
        messageGUID: String,
        useOverlay: Bool,
        reaction: WritableReaction,
        enabled: Bool
    ) {
        self.conversationGUID = conversationGUID
        self.messageGUID = messageGUID
        self.useOverlay = useOverlay
        self.reaction = reaction
        self.enabled = enabled
    }
}

public protocol MessageReactionWriting: Sendable {
    func setReaction(_ request: ReactionDispatchRequest) async throws
}
