import AppKit
import ApplicationServices
import Foundation

extension MacOSAccessibilityMessagesDriver {
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

    @MainActor func openMessagesURL(_ url: URL, failure: String) async throws {
        if let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.messagesBundleIdentifier
        ).first {
            guard application.activate(options: [.activateAllWindows]) else {
                throw AccessibilityDriverFailure("Could not activate Messages.")
            }
            try await waitUntil("Messages did not become active.") {
                application.isActive
            }
        }
        guard NSWorkspace.shared.open(url) else {
            throw AccessibilityDriverFailure(failure)
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

    @MainActor func transcript(
        in window: AXUIElement,
        reply: Bool
    ) async throws -> AXUIElement {
        try await waitUntilValue(
            reply ? "The reply transcript did not become visible." : "The conversation transcript was not found."
        ) {
            try self.transcriptCandidate(in: window, reply: reply)
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

    func actionNames(of element: AXUIElement) throws -> [String] {
        var value: CFArray?
        let result = AXUIElementCopyActionNames(element, &value)
        if result == .actionUnsupported || result == .noValue { return [] }
        guard result == .success else {
            throw AccessibilityDriverFailure("Could not read AX actions, error \(result.rawValue).")
        }
        return value as? [String] ?? []
    }

    func elementsAttribute(_ name: String, of element: AXUIElement) throws -> [AXUIElement] {
        guard let value = try attribute(name, of: element) else { return [] }
        return value as? [AXUIElement] ?? []
    }

    func stringAttribute(_ name: String, of element: AXUIElement) throws -> String? {
        try attribute(name, of: element) as? String
    }

    func boolAttribute(_ name: String, of element: AXUIElement) throws -> Bool {
        (try attribute(name, of: element) as? Bool) ?? false
    }

    func attribute(_ name: String, of element: AXUIElement) throws -> CFTypeRef? {
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

    func setValue(_ value: String, on element: AXUIElement) throws {
        let result = AXUIElementSetAttributeValue(element, "AXValue" as CFString, value as CFTypeRef)
        guard result == .success else {
            throw AccessibilityDriverFailure("Could not set the Messages composer text.")
        }
    }

    func composerText(_ element: AXUIElement) throws -> String {
        let value = try attribute("AXValue", of: element)
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let text = value as? String { return text }
        if value == nil { return "" }
        throw AccessibilityDriverFailure("Could not read the Messages composer text.")
    }

    func postKey(
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

    @MainActor func waitUntilValue<T>(
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

    private func elementAttribute(_ name: String, of element: AXUIElement) throws -> AXUIElement? {
        guard let value = try attribute(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
}

struct AccessibilityDriverFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
