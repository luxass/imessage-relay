import Foundation

struct ServerConfig: Sendable {
    /// Normalized recipient allowlist. **Empty set denies every send** — the
    /// relay never messages anyone unless explicitly configured to.
    let allowedRecipients: Set<String>
    /// When set, every request must carry `Authorization: Bearer <token>`.
    let token: String?
    let databasePath: String

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        let configuredPath = environment["RELAY_CHAT_DB_PATH"] ?? "~/Library/Messages/chat.db"
        let recipients = environment["RELAY_ALLOWED_RECIPIENTS"]?
            .split(separator: ",")
            .map { normalizeRecipient(String($0)) }
            .filter { !$0.isEmpty } ?? []
        return ServerConfig(
            allowedRecipients: Set(recipients),
            token: environment["RELAY_TOKEN"].flatMap { $0.isEmpty ? nil : $0 },
            databasePath: (configuredPath as NSString).expandingTildeInPath
        )
    }

    /// Every actual recipient must be allowlisted. An empty allowlist denies
    /// every send, including sends with no resolved recipients.
    func allowsAll(recipients: [String]) -> Bool {
        guard !allowedRecipients.isEmpty, !recipients.isEmpty else { return false }
        return recipients.allSatisfy {
            allowedRecipients.contains(Self.normalizeRecipient($0))
        }
    }

    /// Recipients are compared loosely: case-insensitive, and phone numbers
    /// match regardless of spaces, dashes, or parentheses.
    static func normalizeRecipient(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789@.+")
        let scalars = value.lowercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
