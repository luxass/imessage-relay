import Foundation
import RelayCore

enum ServerConfigError: Error, Equatable, CustomStringConvertible {
    case missingToken
    case invalidMediaLimit

    var description: String {
        switch self {
        case .missingToken: "RELAY_TOKEN must contain a bearer token."
        case .invalidMediaLimit: "RELAY_MAX_MEDIA_BYTES must be a positive integer no larger than 25 MiB."
        }
    }
}

struct ServerConfig: Sendable {
    let token: String
    let databasePath: String
    let attachmentDirectory: String
    let mediaDirectory: String
    let stateDatabasePath: String
    let senderAccountID: String?
    let allowedRecipients: [String]
    let maximumMediaBytes: Int64

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Self {
        guard let token = nonempty(environment["RELAY_TOKEN"]) else {
            throw ServerConfigError.missingToken
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let databasePath = expanded(
            environment["RELAY_CHAT_DB_PATH"] ?? "~/Library/Messages/chat.db"
        )
        let attachmentDirectory = expanded(
            environment["RELAY_ATTACHMENT_DIRECTORY"] ?? "~/Library/Messages/Attachments"
        )
        let mediaDirectory = expanded(
            environment["RELAY_MEDIA_DIRECTORY"]
                ?? home.appendingPathComponent("Library/Application Support/imessage-relay/media").path
        )
        let stateDatabasePath = expanded(
            environment["RELAY_STATE_DB_PATH"]
                ?? home.appendingPathComponent("Library/Application Support/imessage-relay/relay.db").path
        )
        let maximumMediaBytes: Int64
        if let configured = environment["RELAY_MAX_MEDIA_BYTES"] {
            guard let parsed = Int64(configured), parsed > 0, parsed <= 25 * 1024 * 1024 else {
                throw ServerConfigError.invalidMediaLimit
            }
            maximumMediaBytes = parsed
        } else {
            maximumMediaBytes = 25 * 1024 * 1024
        }
        let recipients = environment["RELAY_ALLOWED_RECIPIENTS"]?
            .split(separator: ",")
            .map(String.init) ?? []
        return ServerConfig(
            token: token,
            databasePath: databasePath,
            attachmentDirectory: attachmentDirectory,
            mediaDirectory: mediaDirectory,
            stateDatabasePath: stateDatabasePath,
            senderAccountID: nonempty(environment["RELAY_SENDER_ACCOUNT_ID"]),
            allowedRecipients: recipients,
            maximumMediaBytes: maximumMediaBytes
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func expanded(_ value: String) -> String {
        (value as NSString).expandingTildeInPath
    }
}
