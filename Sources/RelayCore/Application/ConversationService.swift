public struct ConversationService: Sendable {
    private let store: any ConversationStoring
    private let messages: any MessageStoring
    private let readWriter: any ConversationReadWriting
    private let verificationTimeout: Duration
    private let verificationPollInterval: Duration
    private let typing: (any TypingLeaseStopping)?

    public init(
        store: any ConversationStoring,
        messages: any MessageStoring,
        readWriter: any ConversationReadWriting,
        verificationTimeout: Duration = .seconds(5),
        verificationPollInterval: Duration = .milliseconds(100),
        typing: (any TypingLeaseStopping)? = nil
    ) {
        self.store = store
        self.messages = messages
        self.readWriter = readWriter
        self.verificationTimeout = verificationTimeout
        self.verificationPollInterval = verificationPollInterval
        self.typing = typing
    }

    public func list(
        limit: Int,
        cursor: Cursor?,
        unreadOnly: Bool,
        participant: RecipientHandle? = nil
    ) async throws -> PaginatedResponse<Conversation> {
        try await store.listConversations(
            options: ConversationListOptions(
                limit: limit,
                cursor: cursor,
                unreadOnly: unreadOnly,
                participant: participant
            )
        )
    }

    public func get(id: ConversationID) async throws -> Conversation {
        guard let conversation = try await store.conversation(id: id) else {
            throw RelayServiceError.unknownConversation
        }
        return conversation
    }

    public func markRead(
        id: ConversationID,
        requestID: RequestID
    ) async throws -> ConversationReadResponse {
        guard let conversation = try await store.conversation(id: id) else {
            throw RelayServiceError.unknownConversation
        }
        guard conversation.unreadCount > 0 else {
            return ConversationReadResponse(
                requestID: requestID,
                conversationID: id,
                status: .unchanged
            )
        }
        guard let conversationGUID = conversation.providerGUID else {
            throw RelayServiceError.unsupportedCapability(
                "The conversation has no provider GUID for a safe mark-read operation."
            )
        }
        let page = try await messages.listMessages(
            conversationID: id,
            options: MessageListOptions(limit: 1)
        )
        guard let anchorMessageGUID = page.items.first?.providerGUID else {
            throw RelayServiceError.unsupportedCapability(
                "The conversation has no provider message anchor for a safe mark-read operation."
            )
        }

        try await typing?.stopActiveTyping()

        do {
            try await readWriter.markRead(ConversationReadWriteRequest(
                conversationGUID: conversationGUID,
                anchorMessageGUID: anchorMessageGUID
            ))
        } catch ConversationReadWriterError.unsupported(let detail) {
            throw RelayServiceError.unsupportedCapability(detail)
        } catch ConversationReadWriterError.unavailable(let detail) {
            throw RelayServiceError.messagesUnavailable(detail)
        } catch ConversationReadWriterError.notStarted(let detail) {
            throw RelayServiceError.messagesUnavailable(detail)
        } catch ConversationReadWriterError.uncertain(let detail) {
            throw RelayServiceError.uncertainRead(detail)
        }

        let deadline = ContinuousClock.now.advanced(by: verificationTimeout)
        repeat {
            guard let updated = try await store.conversation(id: id) else {
                throw RelayServiceError.unknownConversation
            }
            if updated.unreadCount == 0 {
                return ConversationReadResponse(
                    requestID: requestID,
                    conversationID: id,
                    status: .applied
                )
            }
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: verificationPollInterval)
        } while true

        throw RelayServiceError.uncertainRead(
            "Messages did not confirm that the conversation was marked read. Refetch the conversation before retrying."
        )
    }
}
