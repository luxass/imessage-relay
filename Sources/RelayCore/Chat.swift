public struct Chat: Codable, Sendable {
    public var id: Int64
    public var guid: String
    public var identifier: String
    public var name: String
    public var displayName: String?
    public var service: String
    public var isGroup: Bool
    public var participants: [String]
    public var lastMessageAt: String?
    public var unreadCount: Int

    enum CodingKeys: String, CodingKey {
        case id, guid, identifier, name
        case displayName = "display_name"
        case service
        case isGroup = "is_group"
        case participants
        case lastMessageAt = "last_message_at"
        case unreadCount = "unread_count"
    }

    public init(
        id: Int64,
        guid: String,
        identifier: String,
        name: String,
        displayName: String?,
        service: String,
        isGroup: Bool,
        participants: [String],
        lastMessageAt: String?,
        unreadCount: Int
    ) {
        self.id = id
        self.guid = guid
        self.identifier = identifier
        self.name = name
        self.displayName = displayName
        self.service = service
        self.isGroup = isGroup
        self.participants = participants
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
    }

    /// Optional fields are omitted rather than encoded as null.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(guid, forKey: .guid)
        try c.encode(identifier, forKey: .identifier)
        try c.encode(name, forKey: .name)
        if let displayName, !displayName.isEmpty {
            try c.encode(displayName, forKey: .displayName)
        }
        try c.encode(service, forKey: .service)
        try c.encode(isGroup, forKey: .isGroup)
        try c.encode(participants, forKey: .participants)
        if let lastMessageAt {
            try c.encode(lastMessageAt, forKey: .lastMessageAt)
        }
        try c.encode(unreadCount, forKey: .unreadCount)
    }
}
