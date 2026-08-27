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
    /// Identifies this exact chat.db instance. Rowid cursors are scoped to
    /// one instance and must be discarded when this value changes.
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
        try c.encode(path, forKey: .path)
        try c.encode(fingerprint, forKey: .fingerprint)
        if let error {
            try c.encode(error, forKey: .error)
        }
    }

    private enum CodingKeys: String, CodingKey { case ready, path, fingerprint, error }
}

public struct SenderStatus: Codable, Sendable {
    public var available: Bool
    public var capabilities: [String]

    public init(available: Bool, capabilities: [String]) {
        self.available = available
        self.capabilities = capabilities
    }
}
