public enum DeliveryState: String, Codable, Equatable, Sendable {
    case unknown
    case notSent = "not_sent"
    case sent
    case delivered
    case failed
}

public enum ReadState: String, Codable, Equatable, Sendable {
    case unknown
    case unread
    case read
}

public enum MessageStatus: String, Codable, Equatable, Sendable {
    case accepted
    case queued
    case sending
    case sent
    case delivered
    case read
    case failed
    case unsupported
    case resultUnknown = "result_unknown"
}

public struct ThreadReference: Codable, Equatable, Sendable {
    public let replyToMessageID: MessageID?
    public let threadOriginatorMessageID: MessageID?

    private enum CodingKeys: String, CodingKey {
        case replyToMessageID = "reply_to_message_id"
        case threadOriginatorMessageID = "thread_originator_message_id"
    }

    public init(
        replyToMessageID: MessageID?,
        threadOriginatorMessageID: MessageID?
    ) {
        self.replyToMessageID = replyToMessageID
        self.threadOriginatorMessageID = threadOriginatorMessageID
    }
}

public struct ReplyTarget: Codable, Equatable, Sendable {
    public let messageID: MessageID

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }

    public init(messageID: MessageID) {
        self.messageID = messageID
    }
}

public enum MessagePart: Equatable, Sendable {
    case text(index: Int, text: String)
    case attachment(index: Int, attachment: MediaReference?)
    case unknown(index: Int)

    private enum CodingKeys: String, CodingKey {
        case index, type, text, attachment
    }

    private enum PartType: String, Codable {
        case text, attachment, unknown
    }
}

extension MessagePart: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let index = try container.decode(Int.self, forKey: .index)
        guard index >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .index,
                in: container,
                debugDescription: "A message part index cannot be negative."
            )
        }
        switch try container.decode(PartType.self, forKey: .type) {
        case .text:
            self = .text(index: index, text: try container.decode(String.self, forKey: .text))
        case .attachment:
            self = .attachment(
                index: index,
                attachment: try container.decodeIfPresent(MediaReference.self, forKey: .attachment)
            )
        case .unknown:
            self = .unknown(index: index)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let index, let text):
            try container.encode(index, forKey: .index)
            try container.encode(PartType.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .attachment(let index, let attachment):
            try container.encode(index, forKey: .index)
            try container.encode(PartType.attachment, forKey: .type)
            try container.encode(attachment, forKey: .attachment)
        case .unknown(let index):
            try container.encode(index, forKey: .index)
            try container.encode(PartType.unknown, forKey: .type)
        }
    }
}

public enum ReactionKind: String, Codable, Equatable, Sendable {
    case love
    case like
    case dislike
    case laugh
    case emphasis
    case question
    case custom
    case unknown
}

public enum ReactionAction: String, Codable, Equatable, Sendable {
    case added
    case removed
}

public struct Reaction: Codable, Equatable, Sendable {
    public let id: MessageID
    public let targetPartIndex: Int?
    public let kind: ReactionKind
    public let emoji: String?
    public let action: ReactionAction
    public let sender: RecipientHandle?
    public let isFromMe: Bool
    public let createdAt: Timestamp?

    private enum CodingKeys: String, CodingKey {
        case id, kind, emoji, action, sender
        case targetPartIndex = "target_part_index"
        case isFromMe = "is_from_me"
        case createdAt = "created_at"
    }

    public init(
        id: MessageID,
        targetPartIndex: Int? = nil,
        kind: ReactionKind,
        emoji: String?,
        action: ReactionAction,
        sender: RecipientHandle?,
        isFromMe: Bool,
        createdAt: Timestamp?
    ) {
        self.id = id
        self.targetPartIndex = targetPartIndex
        self.kind = kind
        self.emoji = emoji
        self.action = action
        self.sender = sender
        self.isFromMe = isFromMe
        self.createdAt = createdAt
    }
}

public struct Message: Codable, Equatable, Sendable {
    public let id: MessageID
    public let providerGUID: String?
    public let conversationID: ConversationID
    public let text: String?
    public let sender: RecipientHandle?
    public let isFromMe: Bool
    public let createdAt: Timestamp?
    public let deliveryState: DeliveryState
    public let readState: ReadState
    public let deliveredAt: Timestamp?
    public let readAt: Timestamp?
    public let thread: ThreadReference?
    public var parts: [MessagePart]?
    public var reactions: [Reaction]
    public var attachments: [MediaReference]

    private enum CodingKeys: String, CodingKey {
        case id
        case providerGUID = "provider_guid"
        case conversationID = "conversation_id"
        case text, sender
        case isFromMe = "is_from_me"
        case createdAt = "created_at"
        case deliveryState = "delivery_state"
        case readState = "read_state"
        case deliveredAt = "delivered_at"
        case readAt = "read_at"
        case thread, parts, reactions, attachments
    }

    public init(
        id: MessageID,
        providerGUID: String?,
        conversationID: ConversationID,
        text: String?,
        sender: RecipientHandle?,
        isFromMe: Bool,
        createdAt: Timestamp?,
        deliveryState: DeliveryState,
        readState: ReadState,
        deliveredAt: Timestamp?,
        readAt: Timestamp?,
        thread: ThreadReference?,
        parts: [MessagePart]? = nil,
        reactions: [Reaction],
        attachments: [MediaReference]
    ) {
        self.id = id
        self.providerGUID = providerGUID
        self.conversationID = conversationID
        self.text = text
        self.sender = sender
        self.isFromMe = isFromMe
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.readState = readState
        self.deliveredAt = deliveredAt
        self.readAt = readAt
        self.thread = thread
        self.parts = parts
        self.reactions = reactions
        self.attachments = attachments
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(providerGUID, forKey: .providerGUID)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(text, forKey: .text)
        try container.encode(sender, forKey: .sender)
        try container.encode(isFromMe, forKey: .isFromMe)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(deliveryState, forKey: .deliveryState)
        try container.encode(readState, forKey: .readState)
        try container.encode(deliveredAt, forKey: .deliveredAt)
        try container.encode(readAt, forKey: .readAt)
        try container.encode(thread, forKey: .thread)
        try container.encode(parts, forKey: .parts)
        try container.encode(reactions, forKey: .reactions)
        try container.encode(attachments, forKey: .attachments)
    }
}

public struct MessageContent: Codable, Equatable, Sendable {
    public let text: String?
    public let media: [SendMediaReference]

    public init(text: String?, media: [SendMediaReference]) {
        self.text = text
        self.media = media
    }
}

public struct SendMediaReference: Codable, Equatable, Sendable {
    public let mediaID: MediaID

    private enum CodingKeys: String, CodingKey {
        case mediaID = "media_id"
    }

    public init(mediaID: MediaID) {
        self.mediaID = mediaID
    }
}

public struct SendMessageRequest: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case unsupportedFields([String])
        case missingDestination
        case ambiguousDestination
        case invalidParticipantCount
        case duplicateParticipant(Int)
    }

    public let destination: MessageDestination
    public let content: MessageContent
    public let replyTo: ReplyTarget?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case to
        case participants
        case conversationID = "conversation_id"
        case text
        case media
        case replyTo = "reply_to"
    }

    public init(
        destination: MessageDestination,
        content: MessageContent,
        replyTo: ReplyTarget?
    ) {
        self.destination = destination
        self.content = content
        self.replyTo = replyTo
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        let unsupported = raw.allKeys.map(\.stringValue).filter { !allowed.contains($0) }
        guard unsupported.isEmpty else {
            throw ValidationError.unsupportedFields(unsupported.sorted())
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let conversationID = try container.decodeIfPresent(ConversationID.self, forKey: .conversationID)
        let recipient = try container.decodeIfPresent(String.self, forKey: .to)
            .map(RecipientHandle.resolvable(value:))
        let rawParticipants = try container.decodeIfPresent([String].self, forKey: .participants)
        let participants = try rawParticipants?.map(RecipientHandle.resolvable(value:))
        let destinationCount = [conversationID != nil, recipient != nil, participants != nil]
            .filter { $0 }.count
        guard destinationCount > 0 else { throw ValidationError.missingDestination }
        guard destinationCount == 1 else { throw ValidationError.ambiguousDestination }
        if let conversationID {
            destination = .conversation(conversationID)
        } else if let recipient {
            destination = .recipient(recipient)
        } else if let participants {
            guard participants.count >= 2 else { throw ValidationError.invalidParticipantCount }
            var seen: Set<String> = []
            for (index, participant) in participants.enumerated() {
                let key = "\(participant.type.rawValue)\u{0}\(participant.value)"
                guard seen.insert(key).inserted else {
                    throw ValidationError.duplicateParticipant(index)
                }
            }
            destination = .participants(participants)
        } else {
            throw ValidationError.missingDestination
        }
        content = MessageContent(
            text: try container.decodeIfPresent(String.self, forKey: .text),
            media: try container.decodeIfPresent([SendMediaReference].self, forKey: .media) ?? []
        )
        replyTo = try container.decodeIfPresent(ReplyTarget.self, forKey: .replyTo)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch destination {
        case .conversation(let id): try container.encode(id, forKey: .conversationID)
        case .recipient(let handle): try container.encode(handle.displayValue ?? handle.value, forKey: .to)
        case .participants(let handles):
            try container.encode(handles.map { $0.displayValue ?? $0.value }, forKey: .participants)
        }
        try container.encodeIfPresent(content.text, forKey: .text)
        if !content.media.isEmpty { try container.encode(content.media, forKey: .media) }
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
    }
}

public enum SendCorrelationStatus: String, Codable, Equatable, Sendable {
    case pending
    case partial
    case complete
    case ambiguous
}

public struct MessageReceipt: Codable, Equatable, Sendable {
    public let messageID: MessageID
    public let status: MessageStatus

    private enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case status
    }

    public init(messageID: MessageID, status: MessageStatus) {
        self.messageID = messageID
        self.status = status
    }
}

public struct MediaReceipt: Codable, Equatable, Sendable {
    public let requestedMediaID: MediaID
    public let mediaID: MediaID?
    public let messageID: MessageID?

    private enum CodingKeys: String, CodingKey {
        case requestedMediaID = "requested_media_id"
        case mediaID = "media_id"
        case messageID = "message_id"
    }

    public init(
        requestedMediaID: MediaID,
        mediaID: MediaID?,
        messageID: MessageID?
    ) {
        self.requestedMediaID = requestedMediaID
        self.mediaID = mediaID
        self.messageID = messageID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestedMediaID = try container.decode(MediaID.self, forKey: .requestedMediaID)
        mediaID = try container.decodeIfPresent(MediaID.self, forKey: .mediaID)
        messageID = try container.decodeIfPresent(MessageID.self, forKey: .messageID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestedMediaID, forKey: .requestedMediaID)
        try container.encode(mediaID, forKey: .mediaID)
        try container.encode(messageID, forKey: .messageID)
    }
}

public struct SendMessageResponse: Codable, Equatable, Sendable {
    public let requestID: RequestID
    public let status: MessageStatus
    public let correlationStatus: SendCorrelationStatus
    public let conversationID: ConversationID?
    public let messages: [MessageReceipt]
    public let media: [MediaReceipt]
    public let pollURL: String?

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case status
        case correlationStatus = "correlation_status"
        case conversationID = "conversation_id"
        case messages, media
        case pollURL = "poll_url"
    }

    public init(
        requestID: RequestID,
        status: MessageStatus,
        correlationStatus: SendCorrelationStatus,
        conversationID: ConversationID? = nil,
        messages: [MessageReceipt],
        media: [MediaReceipt],
        pollURL: String?
    ) {
        self.requestID = requestID
        self.status = status
        self.correlationStatus = correlationStatus
        self.conversationID = conversationID
        self.messages = messages
        self.media = media
        self.pollURL = pollURL
    }

    public static func tracking(
        requestID: RequestID,
        status: MessageStatus,
        correlationStatus: SendCorrelationStatus = .pending,
        conversationID: ConversationID? = nil,
        messages: [MessageReceipt] = [],
        media: [MediaReceipt] = []
    ) -> Self {
        Self(
            requestID: requestID,
            status: status,
            correlationStatus: correlationStatus,
            conversationID: conversationID,
            messages: messages,
            media: media,
            pollURL: "/v1/requests/\(requestID.rawValue)"
        )
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
