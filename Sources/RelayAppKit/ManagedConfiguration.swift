import Foundation
import RelayServer

struct ManagedConfiguration: Codable, Sendable {
    static let messagesDatabasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages/chat.db").path

    var hostname: String
    var port: Int
    var allowRemoteConnections: Bool
    var senderAccountID: String?
    var allowedRecipients: [String]
    var maximumMediaBytes: Int64

    init(
        hostname: String = "127.0.0.1",
        port: Int = 8080,
        allowRemoteConnections: Bool = false,
        senderAccountID: String? = nil,
        allowedRecipients: [String] = [],
        maximumMediaBytes: Int64 = 25 * 1024 * 1024
    ) {
        self.hostname = hostname
        self.port = port
        self.allowRemoteConnections = allowRemoteConnections
        self.senderAccountID = senderAccountID
        self.allowedRecipients = allowedRecipients
        self.maximumMediaBytes = maximumMediaBytes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8080
        allowRemoteConnections = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowRemoteConnections
        ) ?? false
        senderAccountID = try container.decodeIfPresent(String.self, forKey: .senderAccountID)
        allowedRecipients = try container.decodeIfPresent(
            [String].self,
            forKey: .allowedRecipients
        ) ?? []
        maximumMediaBytes = try container.decodeIfPresent(
            Int64.self,
            forKey: .maximumMediaBytes
        ) ?? 25 * 1024 * 1024
    }

    func serverConfiguration(token: String) throws -> ServerConfig {
        guard (1...65_535).contains(port) else {
            throw ManagedConfigurationError.invalidPort
        }
        guard maximumMediaBytes > 0, maximumMediaBytes <= 25 * 1024 * 1024 else {
            throw ManagedConfigurationError.invalidMediaLimit
        }
        let loopbackHosts = ["127.0.0.1", "localhost", "::1"]
        guard allowRemoteConnections || loopbackHosts.contains(hostname.lowercased()) else {
            throw ManagedConfigurationError.remoteConnectionsRequireOptIn
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let applicationSupport = home.appendingPathComponent(
            "Library/Application Support/imessage-relay",
            isDirectory: true
        )
        return ServerConfig(
            token: token,
            databasePath: Self.messagesDatabasePath,
            attachmentDirectory: home.appendingPathComponent("Library/Messages/Attachments").path,
            mediaDirectory: applicationSupport.appendingPathComponent("media", isDirectory: true).path,
            stateDatabasePath: applicationSupport.appendingPathComponent("relay.db").path,
            senderAccountID: senderAccountID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            allowedRecipients: allowedRecipients,
            maximumMediaBytes: maximumMediaBytes
        )
    }
}

enum ManagedConfigurationError: Error, Equatable, LocalizedError {
    case invalidPort
    case invalidMediaLimit
    case remoteConnectionsRequireOptIn

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "The configured port must be between 1 and 65535."
        case .invalidMediaLimit:
            "maximumMediaBytes must be between 1 byte and 25 MiB."
        case .remoteConnectionsRequireOptIn:
            "Set allowRemoteConnections to true before binding outside loopback."
        }
    }
}

enum ManagedConfigurationStore {
    static let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/imessage-relay", isDirectory: true)
    static let configurationURL = directoryURL.appendingPathComponent("config.json")

    static func loadOrCreate() throws -> ManagedConfiguration {
        try secureApplicationSupportDirectory()
        if !FileManager.default.fileExists(atPath: configurationURL.path) {
            let configuration = ManagedConfiguration()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(configuration)
            data.append(0x0A)
            try data.write(to: configurationURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configurationURL.path
            )
            return configuration
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: configurationURL.path)
        if let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o077 != 0 {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configurationURL.path
            )
        }
        return try JSONDecoder().decode(
            ManagedConfiguration.self,
            from: Data(contentsOf: configurationURL)
        )
    }

    private static func secureApplicationSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
