import Foundation
import Testing

@testable import RelayCore

@Test
func macOSConversationReadWriterUsesTheSharedAccessibilityBoundary() async throws {
    let driver = RecordingReadAccessibilityDriver()
    let writer = MacOSConversationReadWriter(
        permissionChecker: ReadPermissionChecker(trusted: true),
        driver: driver,
        queue: AccessibilityOperationQueue(label: "synthetic-read-queue")
    )
    let request = ConversationReadWriteRequest(
        conversationGUID: "any;-;friend@example.com",
        anchorMessageGUID: "MESSAGE-GUID"
    )

    try await writer.markRead(request)

    #expect(driver.requests == [AccessibilityMarkReadRequest(
        conversationGUID: request.conversationGUID,
        anchorMessageGUID: request.anchorMessageGUID
    )])
}

@Test
func macOSConversationReadWriterFailsBeforeAutomationWithoutPermission() async throws {
    let driver = RecordingReadAccessibilityDriver()
    let writer = MacOSConversationReadWriter(
        permissionChecker: ReadPermissionChecker(trusted: false),
        driver: driver
    )

    await #expect(throws: ConversationReadWriterError.unavailable(
        "Grant Accessibility access before marking conversations read."
    )) {
        try await writer.markRead(ConversationReadWriteRequest(
            conversationGUID: "any;-;friend@example.com",
            anchorMessageGUID: "MESSAGE-GUID"
        ))
    }
    #expect(driver.requests.isEmpty)
}

private actor ReadPermissionChecker: AccessibilityPermissionChecking {
    let trusted: Bool

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func isTrusted() -> Bool { trusted }
}

private final class RecordingReadAccessibilityDriver: AccessibilityMessagesDriving,
    @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [AccessibilityMarkReadRequest] = []

    var requests: [AccessibilityMarkReadRequest] { lock.withLock { storedRequests } }

    @MainActor func send(_: AccessibilitySendRequest) async throws {}

    @MainActor func markRead(_ request: AccessibilityMarkReadRequest) async throws {
        lock.withLock { storedRequests.append(request) }
    }
}
