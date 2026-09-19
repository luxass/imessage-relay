import Foundation
import Testing

@testable import RelayCore

@Test
func macOSSenderKeepsPlainTextOnAppleScriptAndRoutesAdvancedOperationsSeparately() async throws {
    let processRunner = RoutingProcessRunner()
    let accessibilityDriver = RoutingAccessibilityDriver()
    let sender = MacOSMessageSender(
        configuredAccountID: "account-guid",
        processRunner: processRunner,
        accessibilityPermissionChecker: RoutingPermissionChecker(trusted: true),
        accessibilityDriver: accessibilityDriver
    )

    let plainText = try dispatch(text: "plain")
    let attachment = try dispatch(text: "caption", media: [outboundMedia()])
    let reply = try dispatch(
        text: "reply",
        replyTarget: ReplyTarget(messageID: MessageID(validating: "parent-guid"))
    )

    _ = try await sender.send(plainText)
    _ = try await sender.send(attachment)
    _ = try await sender.send(reply)

    #expect(await processRunner.calls == 1)
    #expect(accessibilityDriver.requests.count == 2)
    #expect(accessibilityDriver.requests.map(\.replyMessageGUID) == [nil, "parent-guid"])
}

@Test
func macOSSenderReportsCapabilitiesFromBothInternalMechanisms() async throws {
    let sender = MacOSMessageSender(
        configuredAccountID: "account-guid",
        accessibilityPermissionChecker: RoutingPermissionChecker(trusted: true),
        accessibilityDriver: RoutingAccessibilityDriver()
    )

    let status = await sender.status()

    #expect(status.id.rawValue == "local-imessage-sender")
    #expect(status.accountIdentity == "account-guid")
    #expect(status.permissions.automation == .unknown)
    #expect(status.permissions.accessibility == .granted)
    #expect(status.capabilities.text == .permissionUnknown)
    #expect(status.capabilities.media == .available)
    #expect(status.capabilities.nativeReply == .available)
    #expect(status.capabilities.groupCreation == .permissionUnknown)
}

@Test
func accessibilityQueueRunsOneUIOperationAtATime() async throws {
    let queue = AccessibilityOperationQueue(label: "synthetic-accessibility-queue")
    let probe = ConcurrencyProbe()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for value in 0..<8 {
            group.addTask {
                try await queue.run {
                    probe.enter(value)
                    defer { probe.leave() }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        }
        try await group.waitForAll()
    }

    #expect(probe.maximumConcurrentOperations == 1)
    #expect(Set(probe.completedValues) == Set(0..<8))
}

private func dispatch(
    text: String?,
    media: [OutboundMedia] = [],
    replyTarget: ReplyTarget? = nil
) throws -> SenderDispatchRequest {
    let conversationID = try ConversationID(validating: "any;-;friend@example.com")
    let recipient = try RecipientHandle(type: .email, value: "friend@example.com")
    return SenderDispatchRequest(
        requestID: try RequestID(validating: UUID().uuidString),
        destination: .conversation(conversationID),
        conversationContext: ConversationSendContext(
            conversationID: conversationID,
            providerGUID: conversationID.rawValue,
            accountID: "account-guid",
            accountLogin: "sender@example.com",
            recipients: [recipient]
        ),
        conversationAnchorMessageID: media.isEmpty
            ? nil
            : try MessageID(validating: "anchor-guid"),
        text: text,
        media: media,
        replyTarget: replyTarget
    )
}

private func outboundMedia() throws -> OutboundMedia {
    OutboundMedia(
        reference: MediaReference(
            mediaID: try MediaID(validating: "upload-fixture"),
            filename: "photo.jpg",
            mimeType: "image/jpeg",
            byteSize: 3,
            source: .upload
        ),
        fileURL: URL(fileURLWithPath: "/synthetic/photo.jpg")
    )
}

private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var concurrentOperations = 0
    private var maximum = 0
    private var completed: [Int] = []

    var maximumConcurrentOperations: Int { lock.withLock { maximum } }
    var completedValues: [Int] { lock.withLock { completed } }

    func enter(_ value: Int) {
        lock.withLock {
            concurrentOperations += 1
            maximum = max(maximum, concurrentOperations)
            completed.append(value)
        }
    }

    func leave() {
        lock.withLock { concurrentOperations -= 1 }
    }
}

private actor RoutingProcessRunner: SendProcessRunning {
    private(set) var calls = 0

    func run(
        executablePath _: String,
        arguments _: [String],
        standardInput _: Data,
        timeout _: Duration,
        terminationGrace _: Duration
    ) -> SendProcessResult {
        calls += 1
        return .exited(0)
    }
}

private actor RoutingPermissionChecker: AccessibilityPermissionChecking {
    let trusted: Bool

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func isTrusted() -> Bool { trusted }
}

private final class RoutingAccessibilityDriver: AccessibilityMessagesDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [AccessibilitySendRequest] = []

    var requests: [AccessibilitySendRequest] { lock.withLock { storedRequests } }

    @MainActor func send(_ request: AccessibilitySendRequest) async throws {
        lock.withLock { storedRequests.append(request) }
    }
}
