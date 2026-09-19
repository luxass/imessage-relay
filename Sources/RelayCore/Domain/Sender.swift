public enum SenderAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
    case permissionUnknown = "permission_unknown"
}

public enum CapabilityAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
    case permissionUnknown = "permission_unknown"
    case unsupported
}

public enum PermissionAvailability: String, Codable, Equatable, Sendable {
    case granted
    case notGranted = "not_granted"
    case unknown
}

public struct SenderPermissions: Codable, Equatable, Sendable {
    public let automation: PermissionAvailability
    public let accessibility: PermissionAvailability

    public init(
        automation: PermissionAvailability,
        accessibility: PermissionAvailability
    ) {
        self.automation = automation
        self.accessibility = accessibility
    }

    public static let unknown = SenderPermissions(
        automation: .unknown,
        accessibility: .unknown
    )
}

public struct SenderCapabilities: Codable, Equatable, Sendable {
    public let text: CapabilityAvailability
    public let media: CapabilityAvailability
    public let nativeReply: CapabilityAvailability
    public let reactions: CapabilityAvailability
    public let groupCreation: CapabilityAvailability

    private enum CodingKeys: String, CodingKey {
        case text, media, reactions
        case nativeReply = "native_reply"
        case groupCreation = "group_creation"
    }

    public init(
        text: CapabilityAvailability,
        media: CapabilityAvailability,
        nativeReply: CapabilityAvailability,
        reactions: CapabilityAvailability = .unsupported,
        groupCreation: CapabilityAvailability = .unsupported
    ) {
        self.text = text
        self.media = media
        self.nativeReply = nativeReply
        self.reactions = reactions
        self.groupCreation = groupCreation
    }
}

public struct Sender: Codable, Equatable, Sendable {
    public let id: SenderID
    public let accountIdentity: String?
    public let login: RecipientHandle?
    public let configured: Bool
    public let availability: SenderAvailability
    public let reason: String?
    public let permissions: SenderPermissions
    public let capabilities: SenderCapabilities

    private enum CodingKeys: String, CodingKey {
        case id
        case accountIdentity = "account_identity"
        case login, configured, availability, reason, permissions, capabilities
    }

    public init(
        id: SenderID,
        accountIdentity: String?,
        login: RecipientHandle?,
        configured: Bool,
        availability: SenderAvailability,
        reason: String?,
        permissions: SenderPermissions = .unknown,
        capabilities: SenderCapabilities
    ) {
        self.id = id
        self.accountIdentity = accountIdentity
        self.login = login
        self.configured = configured
        self.availability = availability
        self.reason = reason
        self.permissions = permissions
        self.capabilities = capabilities
    }
}

public struct DatabaseStatus: Codable, Equatable, Sendable {
    public let ready: Bool
    public let identity: String?
    public let error: String?

    public init(ready: Bool, identity: String?, error: String?) {
        self.ready = ready
        self.identity = identity
        self.error = error
    }
}

public struct ServiceStatus: Codable, Equatable, Sendable {
    public let version: String
    public let healthy: Bool
    public let database: DatabaseStatus
    public let sender: Sender

    public init(version: String, healthy: Bool, database: DatabaseStatus, sender: Sender) {
        self.version = version
        self.healthy = healthy
        self.database = database
        self.sender = sender
    }
}
