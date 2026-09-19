import Foundation

public struct ReactionService: Sendable {
    private let conversations: any ConversationStoring
    private let messages: any MessageStoring
    private let sender: any MessageSender
    private let writer: any MessageReactionWriting
    private let verificationTimeout: Duration
    private let verificationPollInterval: Duration
    private let typing: (any TypingLeaseStopping)?

    public init(
        conversations: any ConversationStoring,
        messages: any MessageStoring,
        sender: any MessageSender,
        writer: any MessageReactionWriting,
        verificationTimeout: Duration = .seconds(5),
        verificationPollInterval: Duration = .milliseconds(100),
        typing: (any TypingLeaseStopping)? = nil
    ) {
        self.conversations = conversations
        self.messages = messages
        self.sender = sender
        self.writer = writer
        self.verificationTimeout = verificationTimeout
        self.verificationPollInterval = verificationPollInterval
        self.typing = typing
    }

    public func set(
        messageID: MessageID,
        request: SetReactionRequest,
        requestID: RequestID
    ) async throws -> ReactionWriteResponse {
        let target = try await target(messageID: messageID)
        let current = Self.currentReaction(in: target.message)
        if current?.kind == request.reaction.reactionKind {
            return ReactionWriteResponse(
                requestID: requestID,
                status: .unchanged,
                messageID: messageID,
                reaction: request.reaction
            )
        }
        return try await apply(
            target: target,
            reaction: request.reaction,
            enabled: true,
            requestID: requestID
        )
    }

    public func clear(
        messageID: MessageID,
        requestID: RequestID
    ) async throws -> ReactionWriteResponse {
        let target = try await target(messageID: messageID)
        guard let current = Self.currentReaction(in: target.message) else {
            return ReactionWriteResponse(
                requestID: requestID,
                status: .unchanged,
                messageID: messageID,
                reaction: nil
            )
        }
        guard let writable = WritableReaction(reactionKind: current.kind) else {
            throw RelayServiceError.unsupportedCapability(
                "Removing this reaction type is not supported."
            )
        }
        return try await apply(
            target: target,
            reaction: writable,
            enabled: false,
            requestID: requestID
        )
    }

    private func apply(
        target: Target,
        reaction: WritableReaction,
        enabled: Bool,
        requestID: RequestID
    ) async throws -> ReactionWriteResponse {
        try await requireCapability()
        try await typing?.stopActiveTyping()
        let previousIDs = Set(target.message.reactions.map(\.id))
        do {
            try await writer.setReaction(ReactionDispatchRequest(
                conversationGUID: target.conversation.providerGUID,
                messageGUID: target.message.providerGUID ?? target.message.id.rawValue,
                useOverlay: target.message.thread?.threadOriginatorMessageID == nil,
                reaction: reaction,
                enabled: enabled
            ))
        } catch MessageSenderError.notStarted(let detail) {
            throw RelayServiceError.senderUnavailable(detail)
        } catch MessageSenderError.unavailable(let detail) {
            throw RelayServiceError.senderUnavailable(detail)
        } catch MessageSenderError.unsupported(let detail) {
            throw RelayServiceError.unsupportedCapability(detail)
        } catch MessageSenderError.uncertain(let detail) {
            throw RelayServiceError.uncertainReaction(detail)
        }

        let deadline = ContinuousClock.now.advanced(by: verificationTimeout)
        repeat {
            guard let updated = try await messages.message(id: target.message.id) else {
                throw RelayServiceError.unknownMessage
            }
            if updated.reactions.contains(where: {
                !previousIDs.contains($0.id)
                    && $0.isFromMe
                    && $0.kind == reaction.reactionKind
                    && $0.action == (enabled ? .added : .removed)
            }) {
                return ReactionWriteResponse(
                    requestID: requestID,
                    status: .applied,
                    messageID: target.message.id,
                    reaction: enabled ? reaction : nil
                )
            }
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: verificationPollInterval)
        } while true

        throw RelayServiceError.uncertainReaction(
            "Messages did not record the requested reaction state. Refetch the message before retrying."
        )
    }

    private func requireCapability() async throws {
        let status = await sender.status()
        switch status.capabilities.reactions {
        case .available:
            return
        case .permissionUnknown, .unavailable:
            throw RelayServiceError.senderUnavailable(
                "Grant Accessibility access before changing reactions."
            )
        case .unsupported:
            throw RelayServiceError.unsupportedCapability("Reaction writes are unsupported.")
        }
    }

    private func target(messageID: MessageID) async throws -> Target {
        guard let message = try await messages.message(id: messageID) else {
            throw RelayServiceError.unknownMessage
        }
        guard let conversation = try await conversations.sendContext(id: message.conversationID) else {
            throw RelayServiceError.unknownConversation
        }
        return Target(message: message, conversation: conversation)
    }

    private static func currentReaction(in message: Message) -> Reaction? {
        guard let latest = message.reactions.last(where: \.isFromMe), latest.action == .added else {
            return nil
        }
        return latest
    }

    private struct Target: Sendable {
        let message: Message
        let conversation: ConversationSendContext
    }
}

private extension WritableReaction {
    init?(reactionKind: ReactionKind) {
        guard let value = Self(rawValue: reactionKind.rawValue) else { return nil }
        self = value
    }

    var reactionKind: ReactionKind {
        ReactionKind(rawValue: rawValue) ?? .unknown
    }
}
