import Foundation

/// A message in a conversation. JSON shape: snake_case keys, ISO 8601 UTC
/// timestamps, optional fields omitted rather than null.
public struct Message: Codable, Sendable {
    public var id: Int64
    public var chatId: Int64
    public var guid: String
    public var text: String
    public var sender: String
    public var isFromMe: Bool
    public var createdAt: String
    /// Delivery timestamp of an outgoing message; omitted when never reported.
    public var deliveredAt: String?
    /// Read receipt of an outgoing message. Only present if the recipient
    /// broadcasts read receipts over iMessage; SMS never does.
    public var readAt: String?
    /// Populated only when requested via `attachments=true`.
    public var attachments: [Attachment]
    /// Present when this message is an inline reply to another message.
    public var replyToGuid: String?
    public var isReaction: Bool?
    public var reactedToGuid: String?
    /// "love", "like", "dislike", "laugh", "emphasis", "question"; nil for
    /// unknown/custom tapback types.
    public var reactionType: String?
    /// Custom emoji text for emoji tapbacks, when present.
    public var reactionEmoji: String?
    /// True when the tapback was added, false when removed.
    public var isReactionAdd: Bool?

    enum CodingKeys: String, CodingKey {
        case id, guid, text, sender, attachments
        case chatId = "chat_id"
        case isFromMe = "is_from_me"
        case createdAt = "created_at"
        case deliveredAt = "delivered_at"
        case readAt = "read_at"
        case replyToGuid = "reply_to_guid"
        case isReaction = "is_reaction"
        case reactedToGuid = "reacted_to_guid"
        case reactionType = "reaction_type"
        case reactionEmoji = "reaction_emoji"
        case isReactionAdd = "is_reaction_add"
    }

    public init(
        id: Int64,
        chatId: Int64,
        guid: String,
        text: String,
        sender: String,
        isFromMe: Bool,
        createdAt: String,
        deliveredAt: String? = nil,
        readAt: String? = nil,
        attachments: [Attachment] = [],
        replyToGuid: String? = nil,
        isReaction: Bool? = nil,
        reactedToGuid: String? = nil,
        reactionType: String? = nil,
        reactionEmoji: String? = nil,
        isReactionAdd: Bool? = nil
    ) {
        self.id = id
        self.chatId = chatId
        self.guid = guid
        self.text = text
        self.sender = sender
        self.isFromMe = isFromMe
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.readAt = readAt
        self.attachments = attachments
        self.replyToGuid = replyToGuid
        self.isReaction = isReaction
        self.reactedToGuid = reactedToGuid
        self.reactionType = reactionType
        self.reactionEmoji = reactionEmoji
        self.isReactionAdd = isReactionAdd
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(chatId, forKey: .chatId)
        try c.encode(guid, forKey: .guid)
        try c.encode(text, forKey: .text)
        try c.encode(sender, forKey: .sender)
        try c.encode(isFromMe, forKey: .isFromMe)
        try c.encode(createdAt, forKey: .createdAt)
        if let deliveredAt {
            try c.encode(deliveredAt, forKey: .deliveredAt)
        }
        if let readAt {
            try c.encode(readAt, forKey: .readAt)
        }
        try c.encode(attachments, forKey: .attachments)
        if let replyToGuid {
            try c.encode(replyToGuid, forKey: .replyToGuid)
        }
        if let isReaction {
            try c.encode(isReaction, forKey: .isReaction)
        }
        if let reactedToGuid {
            try c.encode(reactedToGuid, forKey: .reactedToGuid)
        }
        if let reactionType {
            try c.encode(reactionType, forKey: .reactionType)
        }
        if let reactionEmoji {
            try c.encode(reactionEmoji, forKey: .reactionEmoji)
        }
        if let isReactionAdd {
            try c.encode(isReactionAdd, forKey: .isReactionAdd)
        }
    }
}
