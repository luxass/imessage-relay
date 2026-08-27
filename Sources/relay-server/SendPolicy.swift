import Foundation

/// Decides whether a send may go out. Deny-by-default: with an empty
/// allowlist, nothing is ever sent.
struct SendPolicy: Sendable {
    private let allowedRecipients: Set<String>

    /// `allowedRecipients` must already be normalized (see
    /// `ServerConfig.normalizeRecipient`).
    init(allowedRecipients: Set<String>) {
        self.allowedRecipients = allowedRecipients
    }

    var isDenyAll: Bool { allowedRecipients.isEmpty }

    /// Allowed when *any* candidate recipient matches the allowlist.
    /// Chat-target sends pass the chat's guid, identifier, and every
    /// participant handle, so replying into an allowlisted thread works no
    /// matter which selector was used.
    func allows(recipients: [String]) -> Bool {
        guard !isDenyAll, !recipients.isEmpty else { return false }
        return recipients.contains {
            allowedRecipients.contains(ServerConfig.normalizeRecipient($0))
        }
    }
}
