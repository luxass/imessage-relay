import AppKit
import ApplicationServices

extension MacOSAccessibilityMessagesDriver {
    @MainActor public func send(_ request: AccessibilitySendRequest) async throws {
        let targetURL: URL
        if let replyMessageGUID = request.replyMessageGUID {
            targetURL = try MessagesAccessibilityDeepLink.reply(
                messageGUID: replyMessageGUID,
                useOverlay: request.opensReplyOverlay
            )
        } else if let anchor = request.conversationAnchorMessageGUID {
            targetURL = try MessagesAccessibilityDeepLink.reply(
                messageGUID: anchor,
                useOverlay: false
            )
        } else {
            targetURL = try MessagesAccessibilityDeepLink.conversation(guid: request.conversationGUID)
        }

        var returnPressed = false
        var composer: AXUIElement?
        var shouldRestorePasteboard = false
        var pasteboardBackup: [NSPasteboardItem]?
        defer {
            if shouldRestorePasteboard {
                let pasteboard = NSPasteboard.general
                pasteboard.prepareForNewContents(with: .currentHostOnly)
                if let pasteboardBackup { pasteboard.writeObjects(pasteboardBackup) }
            }
        }

        do {
            if request.resetsReplyTranscriptBeforeOpening,
               let runningApplication = NSRunningApplication.runningApplications(
                   withBundleIdentifier: Self.messagesBundleIdentifier
               ).first {
                let runningAppElement = AXUIElementCreateApplication(
                    runningApplication.processIdentifier
                )
                if let runningWindow = try? await mainWindow(in: runningAppElement) {
                    try await closeReplyTranscriptIfPresent(in: runningWindow)
                }
            }
            try await openMessagesURL(
                targetURL,
                failure: "Messages rejected the target deep link."
            )
            let application = try await messagesApplication()
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let window = try await mainWindow(in: appElement)

            if request.opensReplyOverlay {
                _ = try await transcript(in: window, reply: true)
            }

            if request.requiresReplyAction {
                let messageCell = try await selectedMessageCell(in: window)
                try performReplyAction(on: messageCell)
            } else if request.requiresConversationAnchorSelection {
                _ = try await selectedMessageCell(in: window)
            }

            let selectedComposer = try await messageComposer(
                in: window,
                preferReplyTranscript: request.replyMessageGUID != nil
            )
            composer = selectedComposer
            try await focus(selectedComposer)
            if let text = request.text, !text.isEmpty {
                try await assign(text, to: selectedComposer)
            }
            if !request.mediaURLs.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboardBackup = pasteboard.pasteboardItems?.map(Self.copyPasteboardItem)
                shouldRestorePasteboard = true
                pasteboard.prepareForNewContents(with: .currentHostOnly)
                guard pasteboard.writeObjects(request.mediaURLs.map { $0 as NSURL }) else {
                    throw AccessibilityDriverFailure(
                        "Could not place uploaded media on the local clipboard."
                    )
                }
                try await pastePreparedMedia(into: selectedComposer, application: application)
            }
            guard try characterCount(of: selectedComposer) > 0 else {
                throw AccessibilityDriverFailure("The Messages composer is empty after preparation.")
            }

            try postKey(code: 36, to: application.processIdentifier)
            returnPressed = true
            try await waitUntil("Messages did not clear the composer after Return.") {
                try self.characterCount(of: selectedComposer) == 0
            }
            if request.replyMessageGUID != nil {
                try? await closeReplyTranscriptIfPresent(in: window)
            }
        } catch let error as MessageSenderError {
            throw error
        } catch {
            if !returnPressed, let composer {
                try? setValue("", on: composer)
            }
            if returnPressed {
                throw MessageSenderError.uncertain(String(describing: error))
            }
            throw MessageSenderError.notStarted(String(describing: error))
        }
    }

    private func performReplyAction(on element: AXUIElement) throws {
        guard let action = try replyActionName(on: element) else {
            throw AccessibilityDriverFailure("The selected message has no Reply action.")
        }
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else {
            throw AccessibilityDriverFailure("The Reply action failed with AX error \(result.rawValue).")
        }
    }

    private func replyActionName(on element: AXUIElement) throws -> String? {
        let reply = Bundle(path: Self.replyBundlePath)?
            .localizedString(forKey: "balloon.message.reply", value: "Reply", table: "Accessibility")
            ?? "Reply"
        return try actionNames(of: element).first { $0.hasPrefix("Name:\(reply)") }
    }

    @MainActor private func focus(_ element: AXUIElement) async throws {
        try await waitUntil("Could not focus the Messages composer.") {
            try self.setFocused(element)
            if try self.boolAttribute("AXFocused", of: element) { return true }
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            guard result == .success else {
                throw AccessibilityDriverFailure(
                    "Could not press the Messages composer, AX error \(result.rawValue)."
                )
            }
            return try self.boolAttribute("AXFocused", of: element)
        }
    }

    private func setFocused(_ element: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(element, "AXFocused" as CFString, true as CFTypeRef)
        guard result == .success else {
            throw AccessibilityDriverFailure("Could not focus the Messages composer.")
        }
    }

    @MainActor private func assign(_ value: String, to element: AXUIElement) async throws {
        try await waitUntil("Could not assign text to the Messages composer.") {
            try self.setValue(value, on: element)
            return try self.characterCount(of: element) > 0
        }
    }

    private func characterCount(of element: AXUIElement) throws -> Int {
        if let count = try attribute("AXNumberOfCharacters", of: element) as? NSNumber {
            return count.intValue
        }
        if let value = try stringAttribute("AXValue", of: element) {
            return value.count
        }
        return 0
    }

    @MainActor private func pastePreparedMedia(
        into composer: AXUIElement,
        application: NSRunningApplication
    ) async throws {
        let countBeforePaste = try characterCount(of: composer)
        try postKey(code: 9, flags: .maskCommand, to: application.processIdentifier)
        try await waitUntil("Messages did not paste the uploaded media.") {
            try self.characterCount(of: composer) > countBeforePaste
        }
    }

    private static func copyPasteboardItem(_ item: NSPasteboardItem) -> NSPasteboardItem {
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) {
                copy.setData(data, forType: type)
            }
        }
        return copy
    }
}
