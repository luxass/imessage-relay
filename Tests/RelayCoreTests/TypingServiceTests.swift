import Foundation
import Testing

@testable import RelayCore

@Test
func typingServiceSwitchesOneGlobalLeaseAndStopsItBeforeOtherUIWork() async throws {
    let store = TypingStore()
    let writer = RecordingTypingWriter()
    let service = TypingService(
        conversations: store,
        messages: store,
        writer: writer,
        leaseDuration: .seconds(5)
    )

    let first = try await service.start(
        conversationID: store.firstID,
        requestID: RequestID(validating: "typing-first")
    )
    let second = try await service.start(
        conversationID: store.secondID,
        requestID: RequestID(validating: "typing-second")
    )
    try await service.stopActiveTyping()

    #expect(first.status == .active)
    #expect(first.expiresAt != nil)
    #expect(second.status == .active)
    #expect(writer.calls == [
        .start(store.firstRequest),
        .stop(store.firstRequest),
        .start(store.secondRequest),
        .stop(store.secondRequest),
    ])
}

@Test
func typingServiceExpiresAndClearsItsLease() async throws {
    let store = TypingStore()
    let writer = RecordingTypingWriter()
    let service = TypingService(
        conversations: store,
        messages: store,
        writer: writer,
        leaseDuration: .milliseconds(5)
    )

    _ = try await service.start(
        conversationID: store.firstID,
        requestID: RequestID(validating: "typing-expiry")
    )
    for _ in 0..<100 where writer.calls.count < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(writer.calls == [
        .start(store.firstRequest),
        .stop(store.firstRequest),
    ])
}

@Test
func typingServiceMapsDraftConflictsWithoutClaimingAnActiveLease() async throws {
    let store = TypingStore()
    let writer = RecordingTypingWriter(startError: .draftConflict("Existing draft."))
    let service = TypingService(conversations: store, messages: store, writer: writer)

    await #expect(throws: RelayServiceError.typingConflict("Existing draft.")) {
        try await service.start(
            conversationID: store.firstID,
            requestID: RequestID(validating: "typing-conflict")
        )
    }
    #expect(writer.calls == [.start(store.firstRequest)])
}

private enum TypingWriterCall: Equatable, Sendable {
    case start(ConversationTypingWriteRequest)
    case stop(ConversationTypingWriteRequest)
}

private final class RecordingTypingWriter: ConversationTypingWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let startError: ConversationTypingWriterError?
    private var storedCalls: [TypingWriterCall] = []

    init(startError: ConversationTypingWriterError? = nil) {
        self.startError = startError
    }

    var calls: [TypingWriterCall] { lock.withLock { storedCalls } }

    func startTyping(_ request: ConversationTypingWriteRequest) async throws {
        lock.withLock { storedCalls.append(.start(request)) }
        if let startError { throw startError }
    }

    func stopTyping(_ request: ConversationTypingWriteRequest) async throws {
        lock.withLock { storedCalls.append(.stop(request)) }
    }
}

private final class TypingStore: ConversationStoring, MessageStoring, @unchecked Sendable {
    let firstID: ConversationID
    let secondID: ConversationID
    let firstRequest: ConversationTypingWriteRequest
    let secondRequest: ConversationTypingWriteRequest
    private let conversationsByID: [ConversationID: Conversation]
    private let messagesByConversation: [ConversationID: Message]

    init() {
        do {
            firstID = try ConversationID(validating: "any;-;first@example.com")
            secondID = try ConversationID(validating: "any;-;second@example.com")
            firstRequest = ConversationTypingWriteRequest(
                conversationGUID: firstID.rawValue,
                anchorMessageGUID: "FIRST-MESSAGE",
                isGroup: false
            )
            secondRequest = ConversationTypingWriteRequest(
                conversationGUID: secondID.rawValue,
                anchorMessageGUID: "SECOND-MESSAGE",
                isGroup: false
            )
            let first = try Self.conversation(id: firstID, address: "first@example.com")
            let second = try Self.conversation(id: secondID, address: "second@example.com")
            conversationsByID = [firstID: first, secondID: second]
            messagesByConversation = [
                firstID: try Self.message(id: "FIRST-MESSAGE", conversationID: firstID),
                secondID: try Self.message(id: "SECOND-MESSAGE", conversationID: secondID),
            ]
        } catch {
            preconditionFailure("Invalid typing fixture: \(error)")
        }
    }

    func listConversations(
        options _: ConversationListOptions
    ) async throws -> PaginatedResponse<Conversation> {
        PaginatedResponse(items: Array(conversationsByID.values), nextCursor: nil, hasMore: false)
    }

    func conversation(id: ConversationID) async throws -> Conversation? {
        conversationsByID[id]
    }

    func sendContext(id _: ConversationID) async throws -> ConversationSendContext? { nil }

    func sendContexts(
        matchingExactParticipants _: [RecipientHandle]
    ) async throws -> [ConversationSendContext] { [] }

    func listMessages(
        conversationID: ConversationID,
        options _: MessageListOptions
    ) async throws -> PaginatedResponse<Message> {
        PaginatedResponse(
            items: messagesByConversation[conversationID].map { [$0] } ?? [],
            nextCursor: nil,
            hasMore: false
        )
    }

    func message(id: MessageID) async throws -> Message? {
        messagesByConversation.values.first { $0.id == id }
    }

    private static func conversation(
        id: ConversationID,
        address: String
    ) throws -> Conversation {
        Conversation(
            id: id,
            providerGUID: id.rawValue,
            identifier: address,
            displayName: nil,
            service: "iMessage",
            isGroup: false,
            participants: [try RecipientHandle(type: .email, value: address)],
            unreadCount: 0,
            lastMessageAt: nil
        )
    }

    private static func message(id: String, conversationID: ConversationID) throws -> Message {
        Message(
            id: try MessageID(validating: id),
            providerGUID: id,
            conversationID: conversationID,
            text: "Hello",
            sender: nil,
            isFromMe: false,
            createdAt: nil,
            deliveryState: .unknown,
            readState: .read,
            deliveredAt: nil,
            readAt: nil,
            thread: nil,
            reactions: [],
            attachments: []
        )
    }
}
