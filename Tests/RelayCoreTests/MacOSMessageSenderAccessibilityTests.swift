import Foundation
import Testing

@testable import RelayCore

@Test
func macOSSenderReportsAccessibilityPermissionWithoutTouchingTheDriver() async throws {
    let permission = StubAccessibilityPermissionChecker(trusted: false)
    let driver = RecordingAccessibilityDriver()
    let sender = MacOSMessageSender(
        configuredAccountID: "account-guid",
        accessibilityPermissionChecker: permission,
        accessibilityDriver: driver
    )

    let status = await sender.status()

    #expect(status.permissions.accessibility == .notGranted)
    #expect(status.capabilities.text == .permissionUnknown)
    #expect(status.capabilities.media == .unavailable)
    #expect(status.capabilities.nativeReply == .unavailable)
    #expect(status.capabilities.reactions == .unavailable)
    #expect(driver.requests.isEmpty)
}

@Test
func macOSSenderRoutesReactionWritesThroughAccessibility() async throws {
    let driver = RecordingAccessibilityDriver()
    let sender = MacOSMessageSender(
        configuredAccountID: "account-guid",
        accessibilityPermissionChecker: StubAccessibilityPermissionChecker(trusted: true),
        accessibilityDriver: driver
    )
    let request = ReactionDispatchRequest(
        conversationGUID: "any;-;friend@example.com",
        messageGUID: "message-guid",
        useOverlay: true,
        reaction: .love,
        enabled: true
    )

    try await sender.setReaction(request)

    #expect(driver.reactionRequests == [AccessibilityReactionRequest(
        conversationGUID: "any;-;friend@example.com",
        messageGUID: "message-guid",
        useOverlay: true,
        reaction: .love,
        enabled: true
    )])
}

@Test
func macOSSenderRecordsConversationMediaAndReplyGUIDs() async throws {
    let driver = RecordingAccessibilityDriver()
    let sender = MacOSMessageSender(
        configuredAccountID: "account-guid",
        accessibilityPermissionChecker: StubAccessibilityPermissionChecker(trusted: true),
        accessibilityDriver: driver
    )
    let request = try advancedDispatch()

    let result = try await sender.send(request)

    #expect(result == SenderDispatchResult(messageID: nil, status: .accepted))
    let recorded = try #require(driver.requests.first)
    #expect(recorded.conversationGUID == "any;-;friend@example.com")
    #expect(recorded.conversationAnchorMessageGUID == nil)
    #expect(recorded.replyMessageGUID == "parent-guid")
    #expect(recorded.replyThreadOriginatorGUID == "thread-root-guid")
    #expect(recorded.text == "caption")
    #expect(recorded.mediaURLs.map(\.path) == ["/synthetic/photo.jpg"])
}

@Test
func macOSSenderRejectsDirectRecipientsAndMissingAccessibilityPermissionBeforeDriverUse() async throws {
    let driver = RecordingAccessibilityDriver()
    let trusted = MacOSMessageSender(
        configuredAccountID: "account-guid",
        accessibilityPermissionChecker: StubAccessibilityPermissionChecker(trusted: true),
        accessibilityDriver: driver
    )
    let direct = SenderDispatchRequest(
        requestID: try RequestID(validating: "direct-request"),
        destination: .recipient(try RecipientHandle(type: .email, value: "friend@example.com")),
        conversationContext: nil,
        text: nil,
        media: [try testMedia()],
        replyTarget: nil
    )

    await #expect(throws: MessageSenderError.unsupported(
        "Replies and attachments require an existing conversation."
    )) {
        try await trusted.send(direct)
    }

    let untrusted = MacOSMessageSender(
        configuredAccountID: "account-guid",
        accessibilityPermissionChecker: StubAccessibilityPermissionChecker(trusted: false),
        accessibilityDriver: driver
    )
    await #expect(throws: MessageSenderError.unavailable(
        "Grant Accessibility access to the relay process before sending replies or attachments."
    )) {
        try await untrusted.send(advancedDispatch())
    }
    #expect(driver.requests.isEmpty)
}

@Test
func macOSSenderRejectsUnanchoredConversationMediaBeforeDriverUse() async throws {
    let driver = RecordingAccessibilityDriver()
    let sender = MacOSMessageSender(
        configuredAccountID: "account-guid",
        accessibilityPermissionChecker: StubAccessibilityPermissionChecker(trusted: true),
        accessibilityDriver: driver
    )
    let conversationID = try ConversationID(validating: "any;-;friend@example.com")
    let request = SenderDispatchRequest(
        requestID: try RequestID(validating: "unanchored-media"),
        destination: .conversation(conversationID),
        conversationContext: ConversationSendContext(
            conversationID: conversationID,
            providerGUID: conversationID.rawValue,
            accountID: "account-guid",
            accountLogin: nil,
            recipients: [try RecipientHandle(type: .email, value: "friend@example.com")]
        ),
        text: "caption",
        media: [try testMedia()],
        replyTarget: nil
    )

    await #expect(throws: MessageSenderError.notStarted(
        "A media send requires a stable message anchor in the conversation."
    )) {
        try await sender.send(request)
    }
    #expect(driver.requests.isEmpty)
}

private func advancedDispatch() throws -> SenderDispatchRequest {
    let conversationID = try ConversationID(validating: "any;-;friend@example.com")
    return SenderDispatchRequest(
        requestID: try RequestID(validating: "advanced-request"),
        destination: .conversation(conversationID),
        conversationContext: ConversationSendContext(
            conversationID: conversationID,
            providerGUID: conversationID.rawValue,
            accountID: "account-guid",
            accountLogin: "sender@example.com",
            recipients: [try RecipientHandle(type: .email, value: "friend@example.com")]
        ),
        conversationAnchorMessageID: try MessageID(validating: "parent-guid"),
        text: "caption",
        media: [try testMedia()],
        replyTarget: ReplyTarget(messageID: try MessageID(validating: "parent-guid")),
        replyContext: ReplySendContext(
            messageID: try MessageID(validating: "parent-guid"),
            threadOriginatorMessageID: try MessageID(validating: "thread-root-guid")
        )
    )
}

private func testMedia() throws -> OutboundMedia {
    OutboundMedia(
        reference: MediaReference(
            mediaID: try MediaID(validating: "upload-photo"),
            filename: "photo.jpg",
            mimeType: "image/jpeg",
            byteSize: 3,
            source: .upload
        ),
        fileURL: URL(fileURLWithPath: "/synthetic/photo.jpg")
    )
}

private actor StubAccessibilityPermissionChecker: AccessibilityPermissionChecking {
    let trusted: Bool

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func isTrusted() -> Bool { trusted }
}

private final class RecordingAccessibilityDriver: AccessibilityMessagesDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [AccessibilitySendRequest] = []
    private var storedReactionRequests: [AccessibilityReactionRequest] = []

    var requests: [AccessibilitySendRequest] { lock.withLock { storedRequests } }
    var reactionRequests: [AccessibilityReactionRequest] {
        lock.withLock { storedReactionRequests }
    }

    @MainActor func send(_ request: AccessibilitySendRequest) async throws {
        lock.withLock { storedRequests.append(request) }
    }

    @MainActor func setReaction(_ request: AccessibilityReactionRequest) async throws {
        lock.withLock { storedReactionRequests.append(request) }
    }
}
