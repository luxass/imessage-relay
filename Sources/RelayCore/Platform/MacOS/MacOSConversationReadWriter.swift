public struct MacOSConversationReadWriter: ConversationReadWriting {
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

    public func markRead(_ request: ConversationReadWriteRequest) async throws {
        guard await permissionChecker.isTrusted() else {
            throw ConversationReadWriterError.unavailable(
                "Grant Accessibility access before marking conversations read."
            )
        }
        do {
            try await queue.run {
                try await driver.markRead(AccessibilityMarkReadRequest(
                    conversationGUID: request.conversationGUID,
                    anchorMessageGUID: request.anchorMessageGUID
                ))
            }
        } catch MessageSenderError.unsupported(let detail) {
            throw ConversationReadWriterError.unsupported(detail)
        } catch MessageSenderError.unavailable(let detail) {
            throw ConversationReadWriterError.unavailable(detail)
        } catch MessageSenderError.notStarted(let detail) {
            throw ConversationReadWriterError.notStarted(detail)
        } catch MessageSenderError.uncertain(let detail) {
            throw ConversationReadWriterError.uncertain(detail)
        }
    }
}
