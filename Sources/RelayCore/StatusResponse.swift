public struct StatusResponse: Codable, Sendable {
    public var version: String
    public var database: DatabaseStatus
    public var sender: SenderStatus

    public init(version: String, database: DatabaseStatus, sender: SenderStatus) {
        self.version = version
        self.database = database
        self.sender = sender
    }
}

public struct DatabaseStatus: Codable, Sendable {
    public var ready: Bool
    public var path: String
    /// Identifies the chat.db filesystem instance. Opaque page cursors are
    /// scoped to one instance and must be discarded when this value changes.
    public var fingerprint: String
    public var error: String?

    public init(ready: Bool, path: String, fingerprint: String, error: String?) {
        self.ready = ready
        self.path = path
        self.fingerprint = fingerprint
        self.error = error
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ready, forKey: .ready)
        try c.encode(fingerprint, forKey: .fingerprint)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ready = try c.decode(Bool.self, forKey: .ready)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey { case ready, path, fingerprint, error }
}

public struct SenderStatus: Codable, Sendable {
    public var available: Bool
    public var capabilities: [String]
    public var automationPermission: String

    public init(available: Bool, capabilities: [String], automationPermission: String) {
        self.available = available
        self.capabilities = capabilities
        self.automationPermission = automationPermission
    }

    @available(*, deprecated, message: "Pass automationPermission explicitly")
    public init(available: Bool, capabilities: [String]) {
        self.init(available: available, capabilities: capabilities, automationPermission: "unknown")
    }

    private enum CodingKeys: String, CodingKey {
        case available, capabilities
        case automationPermission = "automation_permission"
    }
}
