import AppKit
import ApplicationServices

extension MacOSAccessibilityMessagesDriver {
    @MainActor public func startTyping(_ request: AccessibilityTypingRequest) async throws {
        try await updateTyping(request, active: true)
    }

    @MainActor public func stopTyping(_ request: AccessibilityTypingRequest) async throws {
        try await updateTyping(request, active: false)
    }

    @MainActor private func updateTyping(
        _ request: AccessibilityTypingRequest,
        active: Bool
    ) async throws {
        var composerChanged = false
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
            guard NSWorkspace.shared.open(targetURL) else {
                throw MessageSenderError.notStarted(
                    "Messages rejected the typing target deep link."
                )
            }
            let application = try await messagesApplication()
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let window = try await mainWindow(in: appElement)
            _ = try await selectedMessageCell(in: window)
            let composer = try await messageComposer(in: window, preferReplyTranscript: false)
            let current = try composerText(composer)

            if active {
                guard current.isEmpty || current == " " else {
                    throw AccessibilityTypingError.draftConflict(
                        "The conversation contains an existing draft."
                    )
                }
                composerChanged = true
                if current == " " { try setValue("", on: composer) }
                try setValue(" ", on: composer)
                try await waitUntil("Messages did not start the typing indicator.") {
                    try self.composerText(composer) == " "
                }
            } else {
                guard current.isEmpty || current == " " else {
                    throw AccessibilityTypingError.draftConflict(
                        "The conversation draft changed while typing was active."
                    )
                }
                guard current == " " else { return }
                composerChanged = true
                try setValue("", on: composer)
                try await waitUntil("Messages did not stop the typing indicator.") {
                    try self.composerText(composer).isEmpty
                }
            }
        } catch let error as AccessibilityTypingError {
            throw error
        } catch let error as MessageSenderError {
            throw error
        } catch {
            if composerChanged {
                throw MessageSenderError.uncertain(String(describing: error))
            }
            throw MessageSenderError.notStarted(String(describing: error))
        }
    }
}
