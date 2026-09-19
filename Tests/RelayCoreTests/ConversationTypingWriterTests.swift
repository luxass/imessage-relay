import Foundation
import Testing

@testable import RelayCore

@Test
func macOSConversationTypingWriterRoutesStartAndStopThroughAccessibility() async throws {
    let driver = RecordingTypingAccessibilityDriver()
    let writer = MacOSConversationTypingWriter(
        permissionChecker: TypingPermissionChecker(trusted: true),
        driver: driver,
        queue: AccessibilityOperationQueue(label: "synthetic-typing-queue")
    )
    let request = ConversationTypingWriteRequest(
        conversationGUID: "any;-;friend@example.com",
        anchorMessageGUID: "MESSAGE-GUID",
        isGroup: false
    )

    try await writer.startTyping(request)
    try await writer.stopTyping(request)

    let native = AccessibilityTypingRequest(
        conversationGUID: request.conversationGUID,
        anchorMessageGUID: request.anchorMessageGUID
    )
    #expect(driver.calls == [.start(native), .stop(native)])
}

@Test
func macOSConversationTypingWriterFailsBeforeAutomationWithoutPermission() async throws {
    let driver = RecordingTypingAccessibilityDriver()
    let writer = MacOSConversationTypingWriter(
        permissionChecker: TypingPermissionChecker(trusted: false),
        driver: driver
    )

    await #expect(throws: ConversationTypingWriterError.unavailable(
        "Grant Accessibility access before changing typing indicators."
    )) {
        try await writer.startTyping(ConversationTypingWriteRequest(
            conversationGUID: "any;-;friend@example.com",
            anchorMessageGUID: "MESSAGE-GUID",
            isGroup: false
        ))
    }
    #expect(driver.calls.isEmpty)
}

@Test
func macOSConversationTypingWriterPreservesDraftConflicts() async throws {
    let driver = RecordingTypingAccessibilityDriver(
        error: AccessibilityTypingError.draftConflict("Existing draft.")
    )
    let writer = MacOSConversationTypingWriter(
        permissionChecker: TypingPermissionChecker(trusted: true),
        driver: driver
    )

    await #expect(throws: ConversationTypingWriterError.draftConflict("Existing draft.")) {
        try await writer.startTyping(ConversationTypingWriteRequest(
            conversationGUID: "any;-;friend@example.com",
            anchorMessageGUID: "MESSAGE-GUID",
            isGroup: false
        ))
    }
}

private enum TypingAccessibilityCall: Equatable, Sendable {
    case start(AccessibilityTypingRequest)
    case stop(AccessibilityTypingRequest)
}

private actor TypingPermissionChecker: AccessibilityPermissionChecking {
    let trusted: Bool

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func isTrusted() -> Bool { trusted }
}

private final class RecordingTypingAccessibilityDriver: AccessibilityMessagesDriving,
    @unchecked Sendable {
    private let lock = NSLock()
    private let error: (any Error)?
    private var storedCalls: [TypingAccessibilityCall] = []

    init(error: (any Error)? = nil) {
        self.error = error
    }

    var calls: [TypingAccessibilityCall] { lock.withLock { storedCalls } }

    @MainActor func send(_: AccessibilitySendRequest) async throws {}

    @MainActor func startTyping(_ request: AccessibilityTypingRequest) async throws {
        lock.withLock { storedCalls.append(.start(request)) }
        if let error { throw error }
    }

    @MainActor func stopTyping(_ request: AccessibilityTypingRequest) async throws {
        lock.withLock { storedCalls.append(.stop(request)) }
        if let error { throw error }
    }
}
