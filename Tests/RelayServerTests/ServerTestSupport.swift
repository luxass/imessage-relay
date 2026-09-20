import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import RelayCore
import Testing

@testable import RelayServer

let testToken = "test-relay-token"

final class ServerTestHarness: @unchecked Sendable {
    let store: APIStore
    let sender: FakeMessageSender
    let reactionWriter: TestReactionWriter
    let readWriter: TestConversationReadWriter
    let typingWriter: TestConversationTypingWriter
    let uploadStore: MediaFileStore
    let config: ServerConfig
    let events: EventService

    private let directory: URL

    init(
        store: APIStore = APIStore(),
        sender: FakeMessageSender = .available(),
        allowedRecipients: [String] = ["+15005550006", "friend@example.com"],
        maximumMediaBytes: Int64 = 1024,
        eventObserver: (any MessageChangeObserving)? = nil,
        typingError: ConversationTypingWriterError? = nil
    ) {
        self.store = store
        self.sender = sender
        reactionWriter = TestReactionWriter(store: store)
        readWriter = TestConversationReadWriter(store: store)
        typingWriter = TestConversationTypingWriter(error: typingError)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-http-tests-\(UUID().uuidString)", isDirectory: true)
        uploadStore = MediaFileStore(directory: directory)
        events = EventService(observer: eventObserver ?? TestMessageChangeObserver())
        config = ServerConfig(
            token: testToken,
            databasePath: "/synthetic/chat.db",
            attachmentDirectory: "/synthetic/Attachments",
            mediaDirectory: directory.path,
            stateDatabasePath: directory.appendingPathComponent("relay.db").path,
            senderAccountID: "account-guid",
            phoneRegion: "US",
            allowedRecipients: allowedRecipients,
            maximumMediaBytes: maximumMediaBytes
        )
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func router() -> Router<RelayRequestContext> {
        let media = MediaService(
            uploads: uploadStore,
            messagesMedia: store,
            policy: MediaPolicy(maximumBytes: config.maximumMediaBytes)
        )
        let typing = TypingService(
            conversations: store,
            messages: store,
            writer: typingWriter,
            leaseDuration: .seconds(5)
        )
        let dependencies = RelayDependencies(
            database: store,
            conversations: ConversationService(
                store: store,
                messages: store,
                readWriter: readWriter,
                verificationTimeout: .milliseconds(50),
                verificationPollInterval: .milliseconds(1),
                typing: typing
            ),
            messages: MessageService(
                conversations: store,
                messages: store,
                sender: sender,
                media: media,
                allowlist: RecipientAllowlist(values: config.allowedRecipients),
                typing: typing
            ),
            reactions: ReactionService(
                conversations: store,
                messages: store,
                sender: sender,
                writer: reactionWriter,
                verificationTimeout: .milliseconds(50),
                verificationPollInterval: .milliseconds(1),
                typing: typing
            ),
            typing: typing,
            media: media,
            sender: sender,
            events: events
        )
        return buildRouter(serverConfig: config, dependencies: dependencies)
    }
}

final class TestMessageChangeObserver: MessageChangeObserving, @unchecked Sendable {
    private let eventsToEmit: [RelayEvent]

    init(events: [RelayEvent] = [
        .streamReady(StreamReadyEvent(databaseIdentity: "fixture-database")),
    ]) {
        eventsToEmit = events
    }

    func events() -> AsyncThrowingStream<RelayEvent, any Error> {
        AsyncThrowingStream { continuation in
            eventsToEmit.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func shutdown() async throws {}
}

final class APIStore: ConversationStoring, MessageStoring, MessageMediaStoring,
    DatabaseStatusProviding, @unchecked Sendable {
    var conversation: Conversation { lock.withLock { storedConversation } }
    let context: ConversationSendContext
    let matchingContexts: [ConversationSendContext]?
    var messages: [Message] { lock.withLock { storedMessages } }
    let database: DatabaseStatus
    let readError: SQLiteStorageError?
    private let lock = NSLock()
    private var storedConversationListOptions: ConversationListOptions?
    private var storedMessageListOptions: MessageListOptions?
    private var storedMessages: [Message]
    private var storedConversation: Conversation

    var lastConversationListOptions: ConversationListOptions? {
        lock.withLock { storedConversationListOptions }
    }

    var lastMessageListOptions: MessageListOptions? {
        lock.withLock { storedMessageListOptions }
    }

    init(
        conversation: Conversation = testConversation(),
        context: ConversationSendContext = testConversationContext(),
        matchingContexts: [ConversationSendContext]? = nil,
        messages: [Message] = testMessages(),
        database: DatabaseStatus = DatabaseStatus(ready: true, identity: "fixture-database", error: nil),
        readError: SQLiteStorageError? = nil
    ) {
        storedConversation = conversation
        self.context = context
        self.matchingContexts = matchingContexts
        storedMessages = messages
        self.database = database
        self.readError = readError
    }

    func databaseStatus() async -> DatabaseStatus { database }

    func listConversations(options: ConversationListOptions) async throws -> PaginatedResponse<Conversation> {
        lock.withLock { storedConversationListOptions = options }
        if let readError { throw readError }
        if options.cursor != nil { throw SQLiteStorageError.invalidCursor }
        return PaginatedResponse(items: [conversation], nextCursor: nil, hasMore: false)
    }

    func conversation(id: ConversationID) async throws -> Conversation? {
        if let readError { throw readError }
        return id == conversation.id ? conversation : nil
    }

    func sendContext(id: ConversationID) async throws -> ConversationSendContext? {
        if let readError { throw readError }
        return id == context.conversationID ? context : nil
    }

    func sendContexts(
        matchingExactParticipants participants: [RecipientHandle]
    ) async throws -> [ConversationSendContext] {
        if let readError { throw readError }
        let expected = Set(participants.map { "\($0.type.rawValue)\u{0}\($0.value)" })
        let candidates = matchingContexts ?? [context]
        return candidates.filter { candidate in
            let actual = Set(candidate.recipients.map {
                "\($0.type.rawValue)\u{0}\($0.value)"
            })
            return expected == actual
        }
    }

    func listMessages(
        conversationID: ConversationID,
        options: MessageListOptions
    ) async throws -> PaginatedResponse<Message> {
        lock.withLock { storedMessageListOptions = options }
        if let readError { throw readError }
        if options.cursor != nil { throw SQLiteStorageError.invalidCursor }
        guard conversationID == conversation.id else { throw RelayServiceError.unknownConversation }
        return PaginatedResponse(
            items: Array(messages.prefix(options.limit)),
            nextCursor: nil,
            hasMore: false
        )
    }

    func message(id: MessageID) async throws -> Message? {
        if let readError { throw readError }
        return messages.first { $0.id == id }
    }

    func media(id: MediaID) async throws -> ReadableMedia? { nil }

    func recordReaction(_ request: ReactionDispatchRequest) throws {
        try lock.withLock {
            guard let index = storedMessages.firstIndex(where: {
                ($0.providerGUID ?? $0.id.rawValue) == request.messageGUID
            }) else {
                throw RelayServiceError.unknownMessage
            }
            var message = storedMessages[index]
            message.reactions.append(Reaction(
                id: try MessageID(validating: "reaction-\(UUID().uuidString)"),
                kind: request.reaction.reactionKind,
                emoji: nil,
                action: request.enabled ? .added : .removed,
                sender: nil,
                isFromMe: true,
                createdAt: Timestamp(Date())
            ))
            storedMessages[index] = message
        }
    }

    func recordRead(_ request: ConversationReadWriteRequest) throws {
        try lock.withLock {
            guard storedConversation.providerGUID == request.conversationGUID else {
                throw RelayServiceError.unknownConversation
            }
            storedConversation = Conversation(
                id: storedConversation.id,
                providerGUID: storedConversation.providerGUID,
                identifier: storedConversation.identifier,
                displayName: storedConversation.displayName,
                service: storedConversation.service,
                isGroup: storedConversation.isGroup,
                participants: storedConversation.participants,
                unreadCount: 0,
                lastMessageAt: storedConversation.lastMessageAt
            )
        }
    }
}

final class TestReactionWriter: MessageReactionWriting, @unchecked Sendable {
    private let store: APIStore
    private let lock = NSLock()
    private var storedRequests: [ReactionDispatchRequest] = []

    init(store: APIStore) {
        self.store = store
    }

    var requests: [ReactionDispatchRequest] { lock.withLock { storedRequests } }

    func setReaction(_ request: ReactionDispatchRequest) async throws {
        lock.withLock { storedRequests.append(request) }
        try store.recordReaction(request)
    }
}

final class TestConversationReadWriter: ConversationReadWriting, @unchecked Sendable {
    private let store: APIStore
    private let lock = NSLock()
    private var storedRequests: [ConversationReadWriteRequest] = []

    init(store: APIStore) {
        self.store = store
    }

    var requests: [ConversationReadWriteRequest] { lock.withLock { storedRequests } }

    func markRead(_ request: ConversationReadWriteRequest) async throws {
        lock.withLock { storedRequests.append(request) }
        try store.recordRead(request)
    }
}

enum TestTypingCall: Equatable, Sendable {
    case start(ConversationTypingWriteRequest)
    case stop(ConversationTypingWriteRequest)
}

final class TestConversationTypingWriter: ConversationTypingWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let error: ConversationTypingWriterError?
    private var storedCalls: [TestTypingCall] = []

    init(error: ConversationTypingWriterError? = nil) {
        self.error = error
    }

    var calls: [TestTypingCall] { lock.withLock { storedCalls } }

    func startTyping(_ request: ConversationTypingWriteRequest) async throws {
        lock.withLock { storedCalls.append(.start(request)) }
        if let error { throw error }
    }

    func stopTyping(_ request: ConversationTypingWriteRequest) async throws {
        lock.withLock { storedCalls.append(.stop(request)) }
        if let error { throw error }
    }
}

private extension WritableReaction {
    var reactionKind: ReactionKind {
        ReactionKind(rawValue: rawValue) ?? .unknown
    }
}

func testConversationID() -> ConversationID {
    guard let id = ConversationID(rawValue: "chat-guid") else {
        preconditionFailure("The test conversation ID is invalid.")
    }
    return id
}

func testConversation() -> Conversation {
    let phone = testPhone()
    return Conversation(
        id: testConversationID(),
        providerGUID: "chat-guid",
        identifier: "+15005550006",
        displayName: nil,
        service: "iMessage",
        isGroup: false,
        participants: [phone],
        unreadCount: 1,
        lastMessageAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
    )
}

func testConversationContext() -> ConversationSendContext {
    ConversationSendContext(
        conversationID: testConversationID(),
        providerGUID: "chat-guid",
        accountID: "account-guid",
        accountLogin: "sender@example.com",
        recipients: [testPhone()]
    )
}

func testMessages() -> [Message] {
    let rootID = testMessageID("message-root")
    return [
        Message(
            id: testMessageID("message-nested"),
            providerGUID: "message-nested",
            conversationID: testConversationID(),
            text: "Nested reply",
            sender: nil,
            isFromMe: true,
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_001)),
            deliveryState: .sent,
            readState: .read,
            deliveredAt: nil,
            readAt: nil,
            thread: ThreadReference(
                replyToMessageID: testMessageID("message-parent"),
                threadOriginatorMessageID: rootID
            ),
            reactions: [Reaction(
                id: testMessageID("reaction-nested"),
                kind: .like,
                emoji: nil,
                action: .added,
                sender: testPhone(),
                isFromMe: false,
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_002))
            )],
            attachments: []
        ),
        Message(
            id: rootID,
            providerGUID: "message-root",
            conversationID: testConversationID(),
            text: "Root",
            sender: testPhone(),
            isFromMe: false,
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)),
            deliveryState: .unknown,
            readState: .unread,
            deliveredAt: nil,
            readAt: nil,
            thread: nil,
            reactions: [],
            attachments: []
        ),
    ]
}

private func testMessageID(_ value: String) -> MessageID {
    guard let id = MessageID(rawValue: value) else {
        preconditionFailure("The test message ID is invalid.")
    }
    return id
}

private func testPhone() -> RecipientHandle {
    do {
        return try RecipientHandle(type: .phone, value: "+1 500 555 0006")
    } catch {
        preconditionFailure("The test phone number is invalid: \(error)")
    }
}

func authorizationHeaders(_ additional: HTTPFields = [:]) -> HTTPFields {
    var headers = additional
    headers[.authorization] = "Bearer \(testToken)"
    return headers
}

func jsonObject(_ buffer: ByteBuffer) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any])
}

func errorBody(_ buffer: ByteBuffer) throws -> APIError {
    try RelayJSON.decoder.decode(APIError.self, from: Data(buffer.readableBytesView))
}
