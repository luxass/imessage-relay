import XCTest
@testable import relay_server

final class ServerConfigTests: XCTestCase {

    private let config = ServerConfig(
        allowedRecipients: [
            ServerConfig.normalizeRecipient("+12025550123"),
            ServerConfig.normalizeRecipient("recipient@example.com"),
        ],
        token: nil,
        databasePath: ""
    )

    func testDenyAllWhenNoAllowlist() {
        let denyAll = ServerConfig(allowedRecipients: [], token: nil, databasePath: "")
        XCTAssertFalse(denyAll.allowsAll(recipients: ["+12025550123"]))
        XCTAssertFalse(denyAll.allowsAll(recipients: ["anything"]))
    }

    func testAllowlistedHandleMatchesAcrossFormats() {
        // Same number, formatted differently.
        XCTAssertTrue(config.allowsAll(recipients: ["+12025550123"]))
        XCTAssertTrue(config.allowsAll(recipients: ["+1 202 555 0123"]))
        XCTAssertTrue(config.allowsAll(recipients: ["+1-202-555-0123"]))
        XCTAssertTrue(config.allowsAll(recipients: ["recipient@example.com"]))
        XCTAssertTrue(config.allowsAll(recipients: ["RECIPIENT@EXAMPLE.COM"]))
    }

    func testNonAllowlistedRecipientsAreDenied() {
        XCTAssertFalse(config.allowsAll(recipients: ["+12025550199"]))
        XCTAssertFalse(config.allowsAll(recipients: ["stranger@example.com"]))
    }

    func testEmptyCandidateListIsDenied() {
        XCTAssertFalse(config.allowsAll(recipients: []))
    }

    func testEveryChatParticipantMustBeAllowlisted() {
        XCTAssertTrue(config.allowsAll(recipients: [
            "+12025550123",
            "recipient@example.com",
        ]))
        XCTAssertFalse(config.allowsAll(recipients: [
            "+12025550123",
            "stranger@example.com",
        ]))
    }

    func testNormalizationStripsFormatting() {
        XCTAssertEqual(ServerConfig.normalizeRecipient("+1 202 555 0123"), ServerConfig.normalizeRecipient("+12025550123"))
        XCTAssertEqual(ServerConfig.normalizeRecipient("(415) 555-1212"), ServerConfig.normalizeRecipient("4155551212"))
    }

    func testAddressPunctuationDoesNotCollide() {
        let pairs = [
            ("recipient_tag@example.com", "recipienttag@example.com"),
            ("recipient-tag@example.com", "recipienttag@example.com"),
            ("first.last@example.com", "firstlast@example.com"),
            ("recipient+tag@example.com", "recipient@example.com"),
            ("usér@example.com", "usr@example.com"),
        ]

        for (first, second) in pairs {
            XCTAssertNotEqual(
                ServerConfig.normalizeRecipient(first),
                ServerConfig.normalizeRecipient(second)
            )
        }
    }

    func testMalformedPhoneLikeHandlesPreserveIdentity() {
        XCTAssertEqual(
            ServerConfig.normalizeRecipient("+1-800-FLOWERS"),
            "+1-800-flowers"
        )
        XCTAssertNotEqual(
            ServerConfig.normalizeRecipient("+1-800-FLOWERS"),
            ServerConfig.normalizeRecipient("+1800flowers")
        )
    }

    func testNormalizationTrimsOnlySurroundingWhitespace() {
        XCTAssertEqual(
            ServerConfig.normalizeRecipient(" \tRECIPIENT_TAG@EXAMPLE.COM\n"),
            "recipient_tag@example.com"
        )
        XCTAssertEqual(ServerConfig.normalizeRecipient(" \t\n"), "")
        XCTAssertNotEqual(
            ServerConfig.normalizeRecipient("opaque handle"),
            ServerConfig.normalizeRecipient("opaquehandle")
        )
    }

    func testEnvironmentAndAuthorizationUseSameCanonicalization() {
        let environmentConfig = ServerConfig.fromEnvironment([
            "RELAY_ALLOWED_RECIPIENTS": " +1 (202) 555-0123 , Recipient_Tag@Example.com ",
            "RELAY_CHAT_DB_PATH": "/synthetic/chat.db",
        ])

        XCTAssertTrue(environmentConfig.allowsAll(recipients: [
            "+12025550123",
            "recipient_tag@example.com",
        ]))
        XCTAssertFalse(environmentConfig.allowsAll(recipients: ["recipienttag@example.com"]))
    }
}

final class BearerAuthTests: XCTestCase {

    func testConstantTimeComparisonAcceptsExactMatch() {
        XCTAssertTrue(BearerAuthMiddleware<RelayRequestContext>.constantTimeEquals("Bearer secret", "Bearer secret"))
        XCTAssertTrue(BearerAuthMiddleware<RelayRequestContext>.constantTimeEquals("", ""))
    }

    func testConstantTimeComparisonRejectsEverythingElse() {
        XCTAssertFalse(BearerAuthMiddleware<RelayRequestContext>.constantTimeEquals("Bearer secret", "Bearer secrets"))
        XCTAssertFalse(BearerAuthMiddleware<RelayRequestContext>.constantTimeEquals("Bearer secret", "bearer secret"))
        XCTAssertFalse(BearerAuthMiddleware<RelayRequestContext>.constantTimeEquals("Basic secret", "Bearer secret"))
        XCTAssertFalse(BearerAuthMiddleware<RelayRequestContext>.constantTimeEquals("Bearer", "Bearer secret"))
    }
}
