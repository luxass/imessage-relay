import Foundation

public struct MacOSConversationTypingWriter: ConversationTypingWriting {
    private let permissionChecker: any AccessibilityPermissionChecking
    private let driver: any AccessibilityMessagesDriving
    private let queue: AccessibilityOperationQueue

    public init(
        permissionChecker: any AccessibilityPermissionChecking =
            MacOSAccessibilityPermissionChecker(),
        driver: any AccessibilityMessagesDriving = MacOSAccessibilityMessagesDriver(),
        queue: AccessibilityOperationQueue = AccessibilityOperationQueue()
    ) {
        self.permissionChecker = permissionChecker
        self.driver = driver
        self.queue = queue
    }

    public func startTyping(_ request: ConversationTypingWriteRequest) async throws {
        try await update(request, active: true)
    }

    public func stopTyping(_ request: ConversationTypingWriteRequest) async throws {
        try await update(request, active: false)
    }

    private func update(
        _ request: ConversationTypingWriteRequest,
        active: Bool
    ) async throws {
        guard await permissionChecker.isTrusted() else {
            throw ConversationTypingWriterError.unavailable(
                "Grant Accessibility access before changing typing indicators."
            )
        }
        if request.isGroup,
           !ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
               majorVersion: 26,
               minorVersion: 0,
               patchVersion: 0
           )) {
            throw ConversationTypingWriterError.unsupported(
                "Group typing indicators require macOS Tahoe or later."
            )
        }
        do {
            let nativeRequest = AccessibilityTypingRequest(
                conversationGUID: request.conversationGUID,
                anchorMessageGUID: request.anchorMessageGUID
            )
            try await queue.run {
                if active {
                    try await driver.startTyping(nativeRequest)
                } else {
                    try await driver.stopTyping(nativeRequest)
                }
            }
        } catch AccessibilityTypingError.draftConflict(let detail) {
            throw ConversationTypingWriterError.draftConflict(detail)
        } catch MessageSenderError.unsupported(let detail) {
            throw ConversationTypingWriterError.unsupported(detail)
        } catch MessageSenderError.unavailable(let detail) {
            throw ConversationTypingWriterError.unavailable(detail)
        } catch MessageSenderError.notStarted(let detail) {
            throw ConversationTypingWriterError.notStarted(detail)
        } catch MessageSenderError.uncertain(let detail) {
            throw ConversationTypingWriterError.uncertain(detail)
        }
    }
}
