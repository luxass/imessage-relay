import AppKit
import ApplicationServices

extension MacOSAccessibilityMessagesDriver {
    @MainActor public func markRead(_ request: AccessibilityMarkReadRequest) async throws {
        var actionAttempted = false
        do {
            let targetURL = try MessagesAccessibilityDeepLink.reply(
                messageGUID: request.anchorMessageGUID,
                useOverlay: false
            )
            if let runningApplication = NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.messagesBundleIdentifier
            ).first {
                let appElement = AXUIElementCreateApplication(runningApplication.processIdentifier)
                if let window = try? await mainWindow(in: appElement) {
                    try await closeReplyTranscriptIfPresent(in: window)
                }
            }
            try await openMessagesURL(
                targetURL,
                failure: "Messages rejected the mark-read target deep link."
            )
            let application = try await messagesApplication()
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let window = try await mainWindow(in: appElement)
            _ = try await selectedMessageCell(in: window)
            actionAttempted = true
            try postKey(
                code: 32,
                flags: [.maskCommand, .maskShift],
                to: application.processIdentifier
            )
        } catch let error as MessageSenderError {
            throw error
        } catch {
            if actionAttempted {
                throw MessageSenderError.uncertain(String(describing: error))
            }
            throw MessageSenderError.notStarted(String(describing: error))
        }
    }
}
