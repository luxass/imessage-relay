import Foundation

public enum RelayEventType: String, Codable, Equatable, Sendable {
    case streamReady = "stream.ready"
    case messageCreated = "message.created"
    case messageUpdated = "message.updated"
    case reactionAdded = "reaction.added"
    case reactionRemoved = "reaction.removed"
    case mediaAvailable = "media.available"
    case streamReset = "stream.reset"
}

public enum MessageChangedField: String, Codable, Equatable, Sendable {
    case deliveryState = "delivery_state"
    case readState = "read_state"
}

public enum StreamResetReason: String, Codable, Equatable, Sendable {
    case databaseChanged = "database_changed"
    case observerFailed = "observer_failed"
    case subscriberOverflow = "subscriber_overflow"
}

public struct StreamReadyEvent: Codable, Equatable, Sendable {
    public let databaseIdentity: String
    public let replaySupported: Bool

    private enum CodingKeys: String, CodingKey {
        case databaseIdentity = "database_identity"
        case replaySupported = "replay_supported"
    }

    public init(databaseIdentity: String, replaySupported: Bool = false) {
        self.databaseIdentity = databaseIdentity
        self.replaySupported = replaySupported
    }
}

public struct MessageCreatedEvent: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let conversationID: ConversationID
    public let isFromMe: Bool
    public let observedAt: Timestamp

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case isFromMe = "is_from_me"
        case observedAt = "observed_at"
    }

    public init(
        messageID: MessageID,
        conversationID: ConversationID,
        isFromMe: Bool,
        observedAt: Timestamp
    ) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.isFromMe = isFromMe
        self.observedAt = observedAt
    }
}

public struct MessageUpdatedEvent: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let conversationID: ConversationID
    public let changedFields: [MessageChangedField]
    public let observedAt: Timestamp

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case changedFields = "changed_fields"
        case observedAt = "observed_at"
    }

    public init(
        messageID: MessageID,
        conversationID: ConversationID,
        changedFields: [MessageChangedField],
        observedAt: Timestamp
    ) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.changedFields = changedFields
        self.observedAt = observedAt
    }
}

public struct ReactionChangedEvent: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let reactionID: MessageID
    public let observedAt: Timestamp

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case reactionID = "reaction_id"
        case observedAt = "observed_at"
    }

    public init(messageID: MessageID, reactionID: MessageID, observedAt: Timestamp) {
        self.messageID = messageID
        self.reactionID = reactionID
        self.observedAt = observedAt
    }
}

public struct MediaAvailableEvent: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let mediaID: MediaID
    public let observedAt: Timestamp

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case mediaID = "media_id"
        case observedAt = "observed_at"
    }

    public init(messageID: MessageID, mediaID: MediaID, observedAt: Timestamp) {
        self.messageID = messageID
        self.mediaID = mediaID
        self.observedAt = observedAt
    }
}

public struct StreamResetEvent: Codable, Equatable, Sendable {
    public let reason: StreamResetReason
    public let message: String
    public let refetchRequired: Bool

    private enum CodingKeys: String, CodingKey {
        case reason, message
        case refetchRequired = "refetch_required"
    }

    public init(reason: StreamResetReason, message: String, refetchRequired: Bool = true) {
        self.reason = reason
        self.message = message
        self.refetchRequired = refetchRequired
    }
}

public enum RelayEventPayload: Encodable, Equatable, Sendable {
    case streamReady(StreamReadyEvent)
    case messageCreated(MessageCreatedEvent)
    case messageUpdated(MessageUpdatedEvent)
    case reactionChanged(ReactionChangedEvent)
    case mediaAvailable(MediaAvailableEvent)
    case streamReset(StreamResetEvent)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .streamReady(let value): try value.encode(to: encoder)
        case .messageCreated(let value): try value.encode(to: encoder)
        case .messageUpdated(let value): try value.encode(to: encoder)
        case .reactionChanged(let value): try value.encode(to: encoder)
        case .mediaAvailable(let value): try value.encode(to: encoder)
        case .streamReset(let value): try value.encode(to: encoder)
        }
    }
}

public enum RelayEvent: Equatable, Sendable {
    case streamReady(StreamReadyEvent)
    case messageCreated(MessageCreatedEvent)
    case messageUpdated(MessageUpdatedEvent)
    case reactionAdded(ReactionChangedEvent)
    case reactionRemoved(ReactionChangedEvent)
    case mediaAvailable(MediaAvailableEvent)
    case streamReset(StreamResetEvent)

    public var type: RelayEventType {
        switch self {
        case .streamReady: .streamReady
        case .messageCreated: .messageCreated
        case .messageUpdated: .messageUpdated
        case .reactionAdded: .reactionAdded
        case .reactionRemoved: .reactionRemoved
        case .mediaAvailable: .mediaAvailable
        case .streamReset: .streamReset
        }
    }

    public var payload: RelayEventPayload {
        switch self {
        case .streamReady(let value): .streamReady(value)
        case .messageCreated(let value): .messageCreated(value)
        case .messageUpdated(let value): .messageUpdated(value)
        case .reactionAdded(let value), .reactionRemoved(let value): .reactionChanged(value)
        case .mediaAvailable(let value): .mediaAvailable(value)
        case .streamReset(let value): .streamReset(value)
        }
    }
}
