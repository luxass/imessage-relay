import Foundation
import Testing

@testable import RelayServer

@Test
func configurationRequiresAuthenticationAndReadsSenderMediaAndAllowlistSettings() throws {
    #expect(throws: ServerConfigError.missingToken) {
        try ServerConfig.fromEnvironment([:])
    }

    let config = try ServerConfig.fromEnvironment([
        "RELAY_TOKEN": " secret ",
        "RELAY_CHAT_DB_PATH": "/tmp/synthetic-chat.db",
        "RELAY_ATTACHMENT_DIRECTORY": "/tmp/synthetic-attachments",
        "RELAY_MEDIA_DIRECTORY": "/tmp/synthetic-media",
        "RELAY_STATE_DB_PATH": "/tmp/synthetic-relay.db",
        "RELAY_SENDER_ACCOUNT_ID": " account-guid ",
        "RELAY_PHONE_REGION": "CA",
        "RELAY_ALLOWED_RECIPIENTS": "+1 500 555 0006,Friend@Example.COM",
        "RELAY_MAX_MEDIA_BYTES": "2048",
    ])

    #expect(config.token == "secret")
    #expect(config.senderAccountID == "account-guid")
    #expect(config.stateDatabasePath == "/tmp/synthetic-relay.db")
    #expect(config.phoneRegion == "CA")
    #expect(config.allowedRecipients == ["+1 500 555 0006", "Friend@Example.COM"])
    #expect(config.maximumMediaBytes == 2048)
}
