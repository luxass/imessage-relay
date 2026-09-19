import Foundation

public struct AccessibilitySendRequest: Equatable, Sendable {
    public let conversationGUID: String
    public let conversationAnchorMessageGUID: String?
    public let text: String?
    public let mediaURLs: [URL]
    public let replyMessageGUID: String?
    public let replyThreadOriginatorGUID: String?

    public init(
        conversationGUID: String,
        conversationAnchorMessageGUID: String? = nil,
        text: String?,
        mediaURLs: [URL],
        replyMessageGUID: String?,
        replyThreadOriginatorGUID: String?
    ) {
        self.conversationGUID = conversationGUID
        self.conversationAnchorMessageGUID = conversationAnchorMessageGUID
        self.text = text
        self.mediaURLs = mediaURLs
        self.replyMessageGUID = replyMessageGUID
        self.replyThreadOriginatorGUID = replyThreadOriginatorGUID
    }

    var opensReplyOverlay: Bool {
        replyMessageGUID != nil && replyThreadOriginatorGUID == nil
    }

    var requiresReplyAction: Bool {
        replyMessageGUID != nil && replyThreadOriginatorGUID != nil
    }

    var requiresConversationAnchorSelection: Bool {
        replyMessageGUID == nil && conversationAnchorMessageGUID != nil
    }

    var resetsReplyTranscriptBeforeOpening: Bool {
        !opensReplyOverlay
    }
}

public struct AccessibilityReactionRequest: Equatable, Sendable {
    public let conversationGUID: String
    public let messageGUID: String
    public let useOverlay: Bool
    public let reaction: WritableReaction
    public let enabled: Bool

    public init(
        conversationGUID: String,
        messageGUID: String,
        useOverlay: Bool,
        reaction: WritableReaction,
        enabled: Bool
    ) {
        self.conversationGUID = conversationGUID
        self.messageGUID = messageGUID
        self.useOverlay = useOverlay
        self.reaction = reaction
        self.enabled = enabled
    }
}

public struct AccessibilityMarkReadRequest: Equatable, Sendable {
    public let conversationGUID: String
    public let anchorMessageGUID: String

    public init(conversationGUID: String, anchorMessageGUID: String) {
        self.conversationGUID = conversationGUID
        self.anchorMessageGUID = anchorMessageGUID
    }
}

public struct AccessibilityTypingRequest: Equatable, Sendable {
    public let conversationGUID: String
    public let anchorMessageGUID: String

    public init(conversationGUID: String, anchorMessageGUID: String) {
        self.conversationGUID = conversationGUID
        self.anchorMessageGUID = anchorMessageGUID
    }
}

public enum AccessibilityTypingError: Error, Equatable, Sendable {
    case draftConflict(String)
}

public protocol AccessibilityMessagesDriving: Sendable {
    @MainActor func send(_ request: AccessibilitySendRequest) async throws
    @MainActor func setReaction(_ request: AccessibilityReactionRequest) async throws
    @MainActor func markRead(_ request: AccessibilityMarkReadRequest) async throws
    @MainActor func startTyping(_ request: AccessibilityTypingRequest) async throws
    @MainActor func stopTyping(_ request: AccessibilityTypingRequest) async throws
}

public extension AccessibilityMessagesDriving {
    @MainActor func setReaction(_: AccessibilityReactionRequest) async throws {
        throw MessageSenderError.unsupported("Reaction writes are unsupported by this driver.")
    }

    @MainActor func markRead(_: AccessibilityMarkReadRequest) async throws {
        throw MessageSenderError.unsupported("Mark-read operations are unsupported by this driver.")
    }

    @MainActor func startTyping(_: AccessibilityTypingRequest) async throws {
        throw MessageSenderError.unsupported("Typing indicators are unsupported by this driver.")
    }

    @MainActor func stopTyping(_: AccessibilityTypingRequest) async throws {
        throw MessageSenderError.unsupported("Typing indicators are unsupported by this driver.")
    }
}
