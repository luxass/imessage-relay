import AppKit
import ApplicationServices
import Foundation

public final class MacOSAccessibilityMessagesDriver: AccessibilityMessagesDriving, @unchecked Sendable {
    static let messagesBundleIdentifier = "com.apple.MobileSMS"
    private static let replyBundlePath =
        "/System/iOSSupport/System/Library/AccessibilityBundles/ChatKitFramework.axbundle"
    private static let chatKitBundlePath =
        "/System/iOSSupport/System/Library/PrivateFrameworks/ChatKit.framework"

    private let timeout: Duration

    public init(timeout: Duration = .seconds(8)) {
        self.timeout = timeout
    }

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
            guard NSWorkspace.shared.open(targetURL) else {
                throw AccessibilityDriverFailure("Messages rejected the target deep link.")
            }
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

    @MainActor public func setReaction(_ request: AccessibilityReactionRequest) async throws {
        var actionAttempted = false
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
            guard NSWorkspace.shared.open(targetURL) else {
                throw AccessibilityDriverFailure("Messages rejected the reaction target deep link.")
            }
            let application = try await messagesApplication()
            let appElement = AXUIElementCreateApplication(application.processIdentifier)
            let window = try await mainWindow(in: appElement)
            let messageCell = try await reactionMessageCell(
                in: window,
                overlay: request.useOverlay,
                reaction: request.reaction
            )
            actionAttempted = true
            try await applyReaction(
                request.reaction,
                enabled: request.enabled,
                to: messageCell,
                in: window
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
            guard NSWorkspace.shared.open(targetURL) else {
                throw AccessibilityDriverFailure("Messages rejected the mark-read target deep link.")
            }
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

    @MainActor func mainWindow(in app: AXUIElement) async throws -> AXUIElement {
        try await waitUntilValue("The Messages main window was not found.") {
            if let main = try self.elementAttribute("AXMainWindow", of: app) {
                return main
            }
            if let focused = try self.elementAttribute("AXFocusedWindow", of: app) {
                return focused
            }
            return try self.elementsAttribute("AXWindows", of: app).first
        }
    }

    @MainActor func messagesApplication() async throws -> NSRunningApplication {
        try await waitUntilValue("Messages did not launch after opening the deep link.") {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.messagesBundleIdentifier
            ).first
        }
    }

    @MainActor func selectedMessageCell(in window: AXUIElement) async throws -> AXUIElement {
        try await waitUntilValue("The message deep link did not select its target message.") {
            guard let transcript = try self.transcriptCandidate(in: window, reply: false) else {
                return nil
            }
            let candidates = try self.elementsAttribute("AXChildren", of: transcript).compactMap {
                try self.elementsAttribute("AXChildren", of: $0).first
            }
            return try candidates.first(where: {
                try self.boolAttribute("AXSelected", of: $0)
            })
        }
    }

    @MainActor private func transcript(
        in window: AXUIElement,
        reply: Bool
    ) async throws -> AXUIElement {
        try await waitUntilValue(
            reply ? "The reply transcript did not become visible." : "The conversation transcript was not found."
        ) {
            try self.transcriptCandidate(in: window, reply: reply)
        }
    }

    private func transcriptCandidate(in window: AXUIElement, reply: Bool) throws -> AXUIElement? {
        let replyTranscriptName = Bundle(path: Self.replyBundlePath)?
            .localizedString(
                forKey: "group.reply.collection",
                value: nil,
                table: "Accessibility"
            )
        return try descendants(of: window).first {
            guard try stringAttribute("AXIdentifier", of: $0) == "TranscriptCollectionView" else {
                return false
            }
            let description = try stringAttribute("AXDescription", of: $0)
            return reply ? description == replyTranscriptName : description != replyTranscriptName
        }
    }

    @MainActor func closeReplyTranscriptIfPresent(in window: AXUIElement) async throws {
        guard let transcript = try transcriptCandidate(in: window, reply: true) else { return }
        let result = AXUIElementPerformAction(transcript, kAXCancelAction as CFString)
        guard result == .success else {
            throw AccessibilityDriverFailure(
                "Could not close the previous reply transcript, AX error \(result.rawValue)."
            )
        }
        try await waitUntil("The previous reply transcript did not close.") {
            try self.normalComposerIsVisible(in: window)
        }
        try await Task.sleep(for: .milliseconds(400))
    }

    private func normalComposerIsVisible(in window: AXUIElement) throws -> Bool {
        let bundle = Bundle(path: Self.chatKitBundlePath)
        let normalPlaceholders = Set([
            bundle?.localizedString(forKey: "MADRID", value: nil, table: "ChatKit"),
            bundle?.localizedString(forKey: "TEXT_MESSAGE", value: nil, table: "ChatKit"),
        ].compactMap { $0 })
        guard !normalPlaceholders.isEmpty else { return false }
        return try descendants(of: window).contains {
            guard try stringAttribute("AXIdentifier", of: $0) == "messageBodyField" else {
                return false
            }
            guard let placeholder = try stringAttribute("AXPlaceholderValue", of: $0) else {
                return false
            }
            return normalPlaceholders.contains(placeholder)
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

    @MainActor func messageComposer(
        in window: AXUIElement,
        preferReplyTranscript: Bool
    ) async throws -> AXUIElement {
        try await waitUntilValue("The Messages composer was not found.") {
            if preferReplyTranscript,
               let transcript = try self.transcriptCandidate(in: window, reply: true) {
                let linked = try self.elementsAttribute("AXLinkedUIElements", of: transcript)
                if let composer = try linked.first(where: {
                    try self.stringAttribute("AXIdentifier", of: $0) == "messageBodyField"
                }) {
                    return composer
                }
            }
            let candidates = try self.descendants(of: window).filter {
                try self.stringAttribute("AXIdentifier", of: $0) == "messageBodyField"
            }
            if let focused = try candidates.first(where: {
                try self.boolAttribute("AXFocused", of: $0)
            }) {
                return focused
            }
            return candidates.first
        }
    }

    @MainActor private func reactionMessageCell(
        in window: AXUIElement,
        overlay: Bool,
        reaction: WritableReaction
    ) async throws -> AXUIElement {
        if !overlay { return try await selectedMessageCell(in: window) }
        let replyTranscript = try await transcript(in: window, reply: true)
        let directPrefix = "Name:\(reactionActionTitle(reaction))"
        let pickerPrefix = "Name:\(reactionPickerActionTitle())"
        return try await waitUntilValue("The reaction target message was not found.") {
            try self.descendants(of: replyTranscript).first { element in
                let actions = try self.actionNames(of: element)
                return actions.contains(where: {
                    $0.hasPrefix(directPrefix) || $0.hasPrefix(pickerPrefix)
                })
            }
        }
    }

    @MainActor private func applyReaction(
        _ reaction: WritableReaction,
        enabled: Bool,
        to messageCell: AXUIElement,
        in window: AXUIElement
    ) async throws {
        let directPrefix = "Name:\(reactionActionTitle(reaction))"
        if let direct = try actionNames(of: messageCell).first(where: { $0.hasPrefix(directPrefix) }) {
            try perform(direct, on: messageCell, failure: "The reaction action failed.")
            return
        }

        let pickerPrefix = "Name:\(reactionPickerActionTitle())"
        guard let picker = try actionNames(of: messageCell).first(where: { $0.hasPrefix(pickerPrefix) }) else {
            throw AccessibilityDriverFailure("The selected message has no reaction action.")
        }
        try perform(picker, on: messageCell, failure: "The reaction picker did not open.")
        let button = try await waitUntilValue("The requested reaction button was not found.") {
            try self.reactionButton(reaction, in: window)
        }
        let selected = try boolAttribute("AXSelected", of: button)
        if selected != enabled {
            try perform(kAXPressAction, on: button, failure: "The reaction button failed.")
        }
    }

    private func reactionButton(
        _ reaction: WritableReaction,
        in window: AXUIElement
    ) throws -> AXUIElement? {
        let elements = try descendants(of: window)
        let identifier = reactionIdentifier(reaction)
        let title = reactionActionTitle(reaction)
        if let exact = try elements.first(where: {
            guard try stringAttribute("AXRole", of: $0) == kAXButtonRole else { return false }
            return try stringAttribute("AXIdentifier", of: $0) == identifier
                || stringAttribute("AXDescription", of: $0) == title
                || stringAttribute("AXTitle", of: $0) == title
        }) {
            return exact
        }
        return nil
    }

    private func reactionPickerActionTitle() -> String {
        Bundle(path: Self.replyBundlePath)?
            .localizedString(
                forKey: "acknowledgments.action.title",
                value: "React",
                table: "Accessibility"
            ) ?? "React"
    }

    private func reactionActionTitle(_ reaction: WritableReaction) -> String {
        let key: String
        switch reaction {
        case .love: key = "acknowledgment.type.heart"
        case .like: key = "acknowledgment.type.thumbs.up"
        case .dislike: key = "acknowledgment.type.thumbs.down"
        case .laugh: key = "acknowledgment.type.ha"
        case .emphasis: key = "acknowledgment.type.exclamation"
        case .question: key = "acknowledgment.type.question.mark"
        }
        return Bundle(path: Self.replyBundlePath)?
            .localizedString(forKey: key, value: reaction.rawValue, table: "Accessibility")
            ?? reaction.rawValue
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

    private func perform(_ action: String, on element: AXUIElement, failure: String) throws {
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else {
            throw AccessibilityDriverFailure("\(failure) AX error \(result.rawValue).")
        }
    }

    private func descendants(of root: AXUIElement) throws -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < pending.count, pending.count < 5_000 {
            let (element, depth) = pending[index]
            index += 1
            result.append(element)
            guard depth < 14 else { continue }
            for child in try elementsAttribute("AXChildren", of: element) {
                pending.append((child, depth + 1))
            }
        }
        return result
    }

    private func actionNames(of element: AXUIElement) throws -> [String] {
        var value: CFArray?
        let result = AXUIElementCopyActionNames(element, &value)
        if result == .actionUnsupported || result == .noValue { return [] }
        guard result == .success else {
            throw AccessibilityDriverFailure("Could not read AX actions, error \(result.rawValue).")
        }
        return value as? [String] ?? []
    }

    private func elementsAttribute(_ name: String, of element: AXUIElement) throws -> [AXUIElement] {
        guard let value = try attribute(name, of: element) else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func elementAttribute(_ name: String, of element: AXUIElement) throws -> AXUIElement? {
        guard let value = try attribute(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) throws -> String? {
        try attribute(name, of: element) as? String
    }

    private func boolAttribute(_ name: String, of element: AXUIElement) throws -> Bool {
        (try attribute(name, of: element) as? Bool) ?? false
    }

    private func attribute(_ name: String, of element: AXUIElement) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .noValue || result == .attributeUnsupported { return nil }
        guard result == .success else {
            throw AccessibilityDriverFailure(
                "Could not read AX attribute \(name), error \(result.rawValue)."
            )
        }
        return value
    }

    private func setFocused(_ element: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(element, "AXFocused" as CFString, true as CFTypeRef)
        guard result == .success else {
            throw AccessibilityDriverFailure("Could not focus the Messages composer.")
        }
    }

    @MainActor private func focus(_ element: AXUIElement) async throws {
        try await waitUntil("Could not focus the Messages composer.") {
            try self.setFocused(element)
            return try self.boolAttribute("AXFocused", of: element)
        }
    }

    func setValue(_ value: String, on element: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(element, "AXValue" as CFString, value as CFTypeRef)
        guard result == .success else {
            throw AccessibilityDriverFailure("Could not set the Messages composer text.")
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

    func composerText(_ element: AXUIElement) throws -> String {
        let value = try attribute("AXValue", of: element)
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let text = value as? String { return text }
        if value == nil { return "" }
        throw AccessibilityDriverFailure("Could not read the Messages composer text.")
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

    private func postKey(
        code: CGKeyCode,
        flags: CGEventFlags = [],
        to processIdentifier: pid_t
    ) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw AccessibilityDriverFailure("Could not create a keyboard event source.")
        }
        for keyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: code,
                keyDown: keyDown
            ) else {
                throw AccessibilityDriverFailure("Could not create a keyboard event.")
            }
            event.flags = flags
            event.postToPid(processIdentifier)
        }
    }

    @MainActor func waitUntil(
        _ failure: String,
        condition: @MainActor () throws -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw AccessibilityDriverFailure(failure)
    }

    @MainActor private func waitUntilValue<T>(
        _ failure: String,
        value: @MainActor () throws -> T?
    ) async throws -> T {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if let result = try value() { return result }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw AccessibilityDriverFailure(failure)
    }
}

enum MessagesAccessibilityDeepLink {
    static func conversation(guid: String) throws -> URL {
        let components = guid.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3 else {
            throw AccessibilityDriverFailure("The conversation GUID has an unsupported format.")
        }
        switch components[1] {
        case "-": return try url(queryName: "address", value: String(components[2]))
        case "+": return try url(queryName: "groupid", value: String(components[2]))
        default: throw AccessibilityDriverFailure("The conversation GUID has an unsupported chat type.")
        }
    }

    static func reply(messageGUID: String, useOverlay: Bool) throws -> URL {
        guard !messageGUID.isEmpty, !messageGUID.contains("_") else {
            throw AccessibilityDriverFailure("The reply message GUID is invalid.")
        }
        return try url(queryName: "message-guid", value: messageGUID, additionalItems: useOverlay
            ? [URLQueryItem(name: "overlay", value: "1")]
            : [])
    }

    private static func url(
        queryName: String,
        value: String,
        additionalItems: [URLQueryItem] = []
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "imessage"
        components.path = "open"
        components.queryItems = [URLQueryItem(name: queryName, value: value)] + additionalItems
        guard let url = components.url else {
            throw AccessibilityDriverFailure("Could not build the Messages deep link.")
        }
        return url
    }
}

private struct AccessibilityDriverFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
