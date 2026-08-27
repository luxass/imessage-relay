import XCTest
@testable import relay_server

final class SendPolicyTests: XCTestCase {

    private let policy = SendPolicy(allowedRecipients: [
        ServerConfig.normalizeRecipient("+4527646535"),
        ServerConfig.normalizeRecipient("Mom@icloud.com"),
    ])

    func testDenyAllWhenNoAllowlist() {
        let denyAll = SendPolicy(allowedRecipients: [])
        XCTAssertFalse(denyAll.allows(recipients: ["+4527646535"]))
        XCTAssertFalse(denyAll.allows(recipients: ["anything"]))
    }

    func testAllowlistedHandleMatchesAcrossFormats() {
        // Same number, formatted differently.
        XCTAssertTrue(policy.allows(recipients: ["+4527646535"]))
        XCTAssertTrue(policy.allows(recipients: ["+45 27 64 65 35"]))
        XCTAssertTrue(policy.allows(recipients: ["+45-27-64-65-35"]))
        XCTAssertTrue(policy.allows(recipients: ["mom@icloud.com"]))
        XCTAssertTrue(policy.allows(recipients: ["MOM@ICLOUD.COM"]))
    }

    func testNonAllowlistedRecipientsAreDenied() {
        XCTAssertFalse(policy.allows(recipients: ["+4599999999"]))
        XCTAssertFalse(policy.allows(recipients: ["stranger@example.com"]))
    }

    func testEmptyCandidateListIsDenied() {
        XCTAssertFalse(policy.allows(recipients: []))
    }

    func testAnyMatchingCandidateAllowsChatTargets() {
        // A chat target passes guid + identifier + participants; one match is enough.
        XCTAssertTrue(policy.allows(recipients: [
            "iMessage;-;+4599999999",
            "+4599999999",
            "+4527646535",
        ]))
        XCTAssertFalse(policy.allows(recipients: [
            "iMessage;-;+4599999999",
            "+4599999999",
        ]))
    }

    func testNormalizationStripsFormatting() {
        XCTAssertEqual(ServerConfig.normalizeRecipient("+45 27 64 65 35"), ServerConfig.normalizeRecipient("+4527646535"))
        XCTAssertEqual(ServerConfig.normalizeRecipient("(415) 555-1212"), ServerConfig.normalizeRecipient("4155551212"))
    }
}

final class BearerAuthTests: XCTestCase {

    func testConstantTimeComparisonAcceptsExactMatch() {
        XCTAssertTrue(BearerAuthMiddleware.constantTimeEquals("Bearer secret", "Bearer secret"))
        XCTAssertTrue(BearerAuthMiddleware.constantTimeEquals("", ""))
    }

    func testConstantTimeComparisonRejectsEverythingElse() {
        XCTAssertFalse(BearerAuthMiddleware.constantTimeEquals("Bearer secret", "Bearer secrets"))
        XCTAssertFalse(BearerAuthMiddleware.constantTimeEquals("Bearer secret", "bearer secret"))
        XCTAssertFalse(BearerAuthMiddleware.constantTimeEquals("Basic secret", "Bearer secret"))
        XCTAssertFalse(BearerAuthMiddleware.constantTimeEquals("Bearer", "Bearer secret"))
    }
}
