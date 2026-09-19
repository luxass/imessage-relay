import Foundation
import Testing

@testable import RelayCore

@Test
func markReadSkipsAccessibilityWhenConversationIsAlreadyRead() async throws {
    let store = ReadServiceStore(unreadCount: 0)
    let writer = CountingConversationReadWriter()
    let service = ConversationService(store: store, messages: store, readWriter: writer)

    let response = try await service.markRead(
        id: store.conversationID,
        requestID: RequestID(validating: "read-request")
    )

    #expect(response.status == .unchanged)
    #expect(writer.requests.isEmpty)
}

@Test
func markReadReportsAnUncertainResultWhenTheDatabaseDoesNotConfirmIt() async throws {
    let store = ReadServiceStore(unreadCount: 1)
    let writer = CountingConversationReadWriter()
    let service = ConversationService(
        store: store,
        messages: store,
        readWriter: writer,
        verificationTimeout: .zero,
        verificationPollInterval: .milliseconds(1)
    )

    await #expect(throws: RelayServiceError.uncertainRead(
        "Messages did not confirm that the conversation was marked read. Refetch the conversation before retrying."
    )) {
        try await service.markRead(
            id: store.conversationID,
            requestID: RequestID(validating: "read-request")
        )
    }
    #expect(writer.requests.count == 1)
}

private final class ReadServiceStore: ConversationStoring, MessageStoring, @unchecked Sendable {
    let conversationID: ConversationID
    private let storedConversation: Conversation
    private let storedMessage: Message

    init(unreadCount: Int) {
        do {
            conversationID = try ConversationID(validating: "any;-;friend@example.com")
            storedConversation = Conversation(
                id: conversationID,
                providerGUID: conversationID.rawValue,
                identifier: "friend@example.com",
                displayName: nil,
                service: "iMessage",
                isGroup: false,
                participants: [try RecipientHandle(type: .email, value: "friend@example.com")],
                unreadCount: unreadCount,
                lastMessageAt: nil
            )
            storedMessage = Message(
                id: try MessageID(validating: "MESSAGE-GUID"),
                providerGUID: "MESSAGE-GUID",
                conversationID: conversationID,
                text: "Hello",
                sender: nil,
                isFromMe: false,
                createdAt: nil,
                deliveryState: .unknown,
                readState: unreadCount == 0 ? .read : .unread,
                deliveredAt: nil,
                readAt: nil,
                thread: nil,
                reactions: [],
                attachments: []
            )
        } catch {
            preconditionFailure("Invalid read-service fixture: \(error)")
        }
    }

    func listConversations(
        options _: ConversationListOptions
    ) async throws -> PaginatedResponse<Conversation> {
        PaginatedResponse(items: [storedConversation], nextCursor: nil, hasMore: false)
    }

    func conversation(id: ConversationID) async throws -> Conversation? {
        id == conversationID ? storedConversation : nil
    }

    func sendContext(id _: ConversationID) async throws -> ConversationSendContext? { nil }

    func sendContexts(
        matchingExactParticipants _: [RecipientHandle]
    ) async throws -> [ConversationSendContext] { [] }

    func listMessages(
        conversationID: ConversationID,
        options _: MessageListOptions
    ) async throws -> PaginatedResponse<Message> {
        guard conversationID == self.conversationID else {
            throw RelayServiceError.unknownConversation
        }
        return PaginatedResponse(items: [storedMessage], nextCursor: nil, hasMore: false)
    }

    func message(id: MessageID) async throws -> Message? {
        id == storedMessage.id ? storedMessage : nil
    }
}

private final class CountingConversationReadWriter: ConversationReadWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [ConversationReadWriteRequest] = []

    var requests: [ConversationReadWriteRequest] { lock.withLock { storedRequests } }

    func markRead(_ request: ConversationReadWriteRequest) async throws {
        lock.withLock { storedRequests.append(request) }
    }
}
