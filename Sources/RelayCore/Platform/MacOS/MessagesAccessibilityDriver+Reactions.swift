import AppKit
import ApplicationServices

extension MacOSAccessibilityMessagesDriver {
    @MainActor public func setReaction(_ request: AccessibilityReactionRequest) async throws {
        var reactionPressed = false
        do {
            let targetURL = try MessagesAccessibilityDeepLink.reply(
                messageGUID: request.messageGUID,
                useOverlay: request.useOverlay
            )
            if !request.useOverlay,
               let runningApplication = NSRunningApplication.runningApplications(
                   withBundleIdentifier: Self.messagesBundleIdentifier
               ).first {
                let appElement = AXUIElementCreateApplication(runningApplication.processIdentifier)
                if let window = try? await mainWindow(in: appElement) {
                    try await closeReplyTranscriptIfPresent(in: window)
                }
            }
            try await openMessagesURL(
                targetURL,
                failure: "Messages rejected the reaction target deep link."
            )
            let application = try await messagesApplication()
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let window = try await mainWindow(in: appElement)
            let messageCell = try await reactionMessageCell(
                in: window,
                overlay: request.useOverlay
            )
            let pickerAction = try await applyReaction(
                request.reaction,
                enabled: request.enabled,
                to: messageCell,
                in: window
            ) {
                reactionPressed = true
            }
            if request.useOverlay {
                if let pickerAction {
                    try await Task.sleep(for: .milliseconds(1_500))
                    dismissReactionPickerIfPresent(
                        action: pickerAction,
                        messageCell: messageCell,
                        window: window
                    )
                }
                try? await closeReplyTranscriptIfPresent(in: window)
            }
        } catch let error as MessageSenderError {
            throw error
        } catch {
            if reactionPressed {
                throw MessageSenderError.uncertain(String(describing: error))
            }
            throw MessageSenderError.notStarted(String(describing: error))
        }
    }

    @MainActor private func reactionMessageCell(
        in window: AXUIElement,
        overlay: Bool
    ) async throws -> AXUIElement {
        if !overlay { return try await selectedMessageCell(in: window) }
        let replyTranscript = try await transcript(in: window, reply: true)
        return try await waitUntilValue("The reaction target message was not found.") {
            do {
                return try self.firstReactionMessageCell(in: replyTranscript)
            } catch {
                return nil
            }
        }
    }

    private func firstReactionMessageCell(in transcript: AXUIElement) throws -> AXUIElement? {
        for container in try elementsAttribute("AXChildren", of: transcript) {
            guard let messageCell = try elementsAttribute("AXChildren", of: container).first else {
                continue
            }
            if accessibilityAction(
                namedOneOf: Self.directReactionActionTitles
                    .union(Self.reactionPickerActionTitles),
                in: try actionNames(of: messageCell)
            ) != nil {
                return messageCell
            }
        }
        return nil
    }

    @MainActor private func applyReaction(
        _ reaction: WritableReaction,
        enabled: Bool,
        to messageCell: AXUIElement,
        in window: AXUIElement,
        beforePress: @MainActor () -> Void
    ) async throws -> String? {
        let actions = try actionNames(of: messageCell)
        if let directAction = accessibilityAction(
            namedOneOf: reactionActionTitles(reaction),
            in: actions
        ) {
            beforePress()
            try perform(directAction, on: messageCell, failure: "The reaction action failed.")
            return nil
        }
        guard let pickerAction = accessibilityAction(
            namedOneOf: Self.reactionPickerActionTitles,
            in: actions
        ) else {
            throw AccessibilityDriverFailure("The selected message has no reaction action.")
        }
        try perform(
            pickerAction,
            on: messageCell,
            failure: "The reaction picker did not open."
        )
        try await Task.sleep(for: .milliseconds(750))
        let button = try await waitUntilValue("The requested reaction button was not found.") {
            do {
                return try self.reactionButton(reaction, in: window)
            } catch {
                return nil
            }
        }
        if try boolAttribute("AXSelected", of: button) != enabled {
            beforePress()
            try perform(kAXPressAction, on: button, failure: "The reaction button failed.")
            try await waitUntil("The reaction button state did not change.") {
                try self.boolAttribute("AXSelected", of: button) == enabled
            }
        }
        return pickerAction
    }

    private func reactionActionTitles(_ reaction: WritableReaction) -> Set<String> {
        switch reaction {
        case .love: Self.loveReactionActionTitles
        case .like: Self.likeReactionActionTitles
        case .dislike: Self.dislikeReactionActionTitles
        case .laugh: Self.laughReactionActionTitles
        case .emphasis: Self.emphasisReactionActionTitles
        case .question: Self.questionReactionActionTitles
        }
    }

    private func reactionButton(
        _ reaction: WritableReaction,
        in window: AXUIElement
    ) throws -> AXUIElement? {
        guard let reactionsView = try reactionsView(in: window) else { return nil }
        if #available(macOS 15, *) {
            guard let picker = try reactionPicker(in: reactionsView) else { return nil }
            let identifier = reactionIdentifier(reaction)
            return try elementsAttribute("AXChildren", of: picker).first {
                try self.stringAttribute("AXIdentifier", of: $0) == identifier
            }
        }
        let buttons = try elementsAttribute("AXChildren", of: reactionsView).filter {
            try self.stringAttribute("AXRole", of: $0) == kAXButtonRole
        }
        let index = reactionIndex(reaction)
        return buttons.indices.contains(index) ? buttons[index] : nil
    }

    private func reactionsView(in window: AXUIElement) throws -> AXUIElement? {
        guard let contentGroup = try elementsAttribute("AXChildren", of: window).first(where: {
            try self.stringAttribute("AXSubrole", of: $0) == "iOSContentGroup"
                && self.stringAttribute("AXRole", of: $0) == kAXGroupRole
        }) else {
            return nil
        }
        return try elementsAttribute("AXChildren", of: contentGroup).first
    }

    private func reactionPicker(in reactionsView: AXUIElement) throws -> AXUIElement? {
        try elementsAttribute("AXChildren", of: reactionsView).first {
            try self.stringAttribute("AXIdentifier", of: $0) == "TapbackPickerCollectionView"
        }
    }

    private func dismissReactionPickerIfPresent(
        action: String,
        messageCell: AXUIElement,
        window: AXUIElement
    ) {
        guard (try? reactionPickerIsVisible(in: window)) == true else { return }
        try? perform(action, on: messageCell, failure: "The reaction picker did not close.")
    }

    private func reactionPickerIsVisible(in window: AXUIElement) throws -> Bool {
        guard let reactionsView = try reactionsView(in: window) else { return false }
        if #available(macOS 15, *) {
            return try reactionPicker(in: reactionsView) != nil
        }
        return try elementsAttribute("AXChildren", of: reactionsView).contains {
            try self.stringAttribute("AXRole", of: $0) == kAXButtonRole
        }
    }

    private func reactionIdentifier(_ reaction: WritableReaction) -> String {
        switch reaction {
        case .love: "heart"
        case .like: "thumbsUp"
        case .dislike: "thumbsDown"
        case .laugh: "ha"
        case .emphasis: "exclamation"
        case .question: "questionMark"
        }
    }

    private func reactionIndex(_ reaction: WritableReaction) -> Int {
        switch reaction {
        case .love: 0
        case .like: 1
        case .dislike: 2
        case .laugh: 3
        case .emphasis: 4
        case .question: 5
        }
    }

    private func perform(_ action: String, on element: AXUIElement, failure: String) throws {
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else {
            throw AccessibilityDriverFailure("\(failure) AX error \(result.rawValue).")
        }
    }
}
