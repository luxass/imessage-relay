import AppKit
import ApplicationServices
import Foundation

struct MessagesTranscriptSnapshot: Equatable, Sendable {
    let transcriptIdentifier: String?
    let transcriptDescription: String?
    let composerIdentifier: String?
    let composerPlaceholder: String?
    let composerIsFocused: Bool
}

func isReplyTranscript(
    _ snapshot: MessagesTranscriptSnapshot,
    normalComposerPlaceholders: Set<String>
) -> Bool {
    guard !normalComposerPlaceholders.isEmpty,
          snapshot.transcriptIdentifier == "TranscriptCollectionView",
          snapshot.composerIdentifier == "messageBodyField",
          snapshot.composerIsFocused,
          let placeholder = snapshot.composerPlaceholder,
          !placeholder.isEmpty else {
        return false
    }
    return !normalComposerPlaceholders.contains(placeholder)
}

func accessibilityAction(namedOneOf titles: Set<String>, in actions: [String]) -> String? {
    actions.first { action in
        guard let firstLine = action.split(separator: "\n", maxSplits: 1).first,
              firstLine.hasPrefix("Name:") else {
            return false
        }
        let title = String(firstLine.dropFirst("Name:".count))
        let normalized = title.hasSuffix("…") ? String(title.dropLast()) : title
        return titles.contains(title) || titles.contains(normalized)
    }
}

func localizedStringVariants(
    bundlePath: String,
    table: String,
    key: String,
    fallbacks: Set<String>
) -> Set<String> {
    guard let bundle = Bundle(path: bundlePath) else { return fallbacks }
    var variants = fallbacks

    let automatic = bundle.localizedString(forKey: key, value: nil, table: table)
    if automatic != key { variants.insert(automatic) }

    if let tableURL = bundle.url(forResource: table, withExtension: "loctable"),
       let data = try? Data(contentsOf: tableURL),
       let tables = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any] {
        for case let localization as [String: Any] in tables.values {
            if let value = localization[key] as? String { variants.insert(value) }
        }
    }

    for localization in bundle.localizations {
        guard let path = bundle.path(forResource: localization, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            continue
        }
        let value = localizedBundle.localizedString(forKey: key, value: nil, table: table)
        if value != key { variants.insert(value) }
    }
    return variants
}

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
        let elements = try descendants(of: window)
        guard let transcript = try elements.first(where: {
            try stringAttribute("AXIdentifier", of: $0) == "TranscriptCollectionView"
        }) else {
            return nil
        }
        let composers = try elements.filter {
            try stringAttribute("AXIdentifier", of: $0) == "messageBodyField"
        }
        let replyVisible = try composers.contains { composer in
            isReplyTranscript(
                MessagesTranscriptSnapshot(
                    transcriptIdentifier: try stringAttribute("AXIdentifier", of: transcript),
                    transcriptDescription: try stringAttribute("AXDescription", of: transcript),
                    composerIdentifier: try stringAttribute("AXIdentifier", of: composer),
                    composerPlaceholder: try stringAttribute("AXPlaceholderValue", of: composer),
                    composerIsFocused: try boolAttribute("AXFocused", of: composer)
                ),
                normalComposerPlaceholders: Self.normalComposerPlaceholders
            )
        }
        return replyVisible == reply ? transcript : nil
    }

    private func normalComposerIsVisible(in window: AXUIElement) throws -> Bool {
        guard !Self.normalComposerPlaceholders.isEmpty else { return false }
        return try descendants(of: window).contains {
            guard try stringAttribute("AXIdentifier", of: $0) == "messageBodyField" else {
                return false
            }
            guard let placeholder = try stringAttribute("AXPlaceholderValue", of: $0) else {
                return false
            }
            return Self.normalComposerPlaceholders.contains(placeholder)
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
