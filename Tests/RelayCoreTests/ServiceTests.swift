import Foundation
import SQLite3
import Testing

@testable import RelayCore

@Test
func sendServiceStopsActiveTypingBeforeDispatch() async throws {
    let stores = StubStores(conversation: nil, context: nil, messages: [])
    let sender = FakeMessageSender.available()
    let typing = RecordingTypingLeaseStopper()
    let service = MessageService(
        conversations: stores,
        messages: stores,
        sender: sender,
        media: MediaService(uploads: MemoryUploadStore(), messagesMedia: NilMessageMediaStore()),
        allowlist: RecipientAllowlist(values: ["friend@example.com"]),
        typing: typing
    )

    _ = try await service.send(
        SendMessageRequest(
            destination: .recipient(try RecipientHandle(type: .email, value: "friend@example.com")),
            content: MessageContent(text: "Hello", media: []),
            replyTo: nil
        ),
        requestID: RequestID(validating: "send-stops-typing"),
        idempotencyKey: nil
    )

    #expect(await typing.stopCount == 1)
    #expect(sender.requests.count == 1)
}

@Test
func sendServiceResolvesConversationAccountMediaAndReplyBeforeDispatch() async throws {
    let conversationID = try ConversationID(validating: "chat-guid")
    let replyID = try MessageID(validating: "reply-guid")
    let threadRootID = try MessageID(validating: "thread-root-guid")
    let mediaID = try MediaID(validating: "upload_fixture")
    let phone = try RecipientHandle(type: .phone, value: "+1 500 555 0006")
    let stores = StubStores(
        conversation: fixtureConversation(id: conversationID, participants: [phone]),
        context: ConversationSendContext(
            conversationID: conversationID,
            providerGUID: conversationID.rawValue,
            accountID: "account-guid",
            accountLogin: "sender@example.com",
            recipients: [phone]
        ),
        messages: [fixtureMessage(
            id: replyID,
            conversationID: conversationID,
            thread: ThreadReference(
                replyToMessageID: threadRootID,
                threadOriginatorMessageID: threadRootID
            )
        )]
    )
    let uploads = MemoryUploadStore(references: [
        mediaID: MediaReference(
            mediaID: mediaID,
            filename: "fixture.jpg",
            mimeType: "image/jpeg",
            byteSize: 10,
            source: .upload
        )
    ])
    let sender = FakeMessageSender.available()
    let service = MessageService(
        conversations: stores,
        messages: stores,
        sender: sender,
        media: MediaService(uploads: uploads, messagesMedia: NilMessageMediaStore()),
        allowlist: RecipientAllowlist(values: ["+15005550006"])
    )

    let response = try await service.send(
        SendMessageRequest(
            destination: .conversation(conversationID),
            content: MessageContent(text: "Hello", media: [SendMediaReference(mediaID: mediaID)]),
            replyTo: ReplyTarget(messageID: replyID)
        ),
        requestID: RequestID(validating: "request-guid"),
        idempotencyKey: "client-operation-1"
    )

    #expect(response.status == .accepted)
    let dispatch = try #require(sender.requests.first)
    #expect(dispatch.destination == .conversation(conversationID))
    #expect(dispatch.conversationContext?.accountID == "account-guid")
    #expect(dispatch.media.map(\.reference.mediaID) == [mediaID])
    #expect(dispatch.replyTarget?.messageID == replyID)
    #expect(dispatch.replyContext?.messageID == replyID)
    #expect(dispatch.replyContext?.threadOriginatorMessageID == threadRootID)
    #expect(dispatch.conversationAnchorMessageID == replyID)
}

@Test
func sendServiceAnchorsStandaloneMediaToTheNewestConversationMessage() async throws {
    let conversationID = try ConversationID(validating: "chat-guid")
    let anchorID = try MessageID(validating: "newest-message-guid")
    let mediaID = try MediaID(validating: "upload_fixture")
    let phone = try RecipientHandle(type: .phone, value: "+15005550006")
    let stores = StubStores(
        conversation: fixtureConversation(id: conversationID, participants: [phone]),
        context: ConversationSendContext(
            conversationID: conversationID,
            providerGUID: conversationID.rawValue,
            accountID: "account-guid",
            accountLogin: nil,
            recipients: [phone]
        ),
        messages: [fixtureMessage(id: anchorID, conversationID: conversationID)]
    )
    let uploads = MemoryUploadStore(references: [
        mediaID: MediaReference(
            mediaID: mediaID,
            filename: "photo.jpg",
            mimeType: "image/jpeg",
            byteSize: 10,
            source: .upload
        )
    ])
    let sender = FakeMessageSender.available()
    let service = MessageService(
        conversations: stores,
        messages: stores,
        sender: sender,
        media: MediaService(uploads: uploads, messagesMedia: NilMessageMediaStore()),
        allowlist: RecipientAllowlist(values: ["+15005550006"])
    )

    _ = try await service.send(
        SendMessageRequest(
            destination: .conversation(conversationID),
            content: MessageContent(text: "caption", media: [SendMediaReference(mediaID: mediaID)]),
            replyTo: nil
        ),
        requestID: RequestID(validating: "media-request"),
        idempotencyKey: nil
    )

    #expect(sender.requests.first?.conversationAnchorMessageID == anchorID)
}

@Test
func sendServiceNormalizesDirectRecipientsForAllowlistChecks() async throws {
    let stores = StubStores(conversation: nil, context: nil, messages: [])
    let sender = FakeMessageSender.available()
    let service = MessageService(
        conversations: stores,
        messages: stores,
        sender: sender,
        media: MediaService(uploads: MemoryUploadStore(), messagesMedia: NilMessageMediaStore()),
        allowlist: RecipientAllowlist(values: ["+1-500-555-0006"])
    )
    let recipient = try RecipientHandle(type: .phone, value: "+1 500 555 0006")

    _ = try await service.send(
        SendMessageRequest(
            destination: .recipient(recipient),
            content: MessageContent(text: "Hello", media: []),
            replyTo: nil
        ),
        requestID: RequestID(validating: "request-direct"),
        idempotencyKey: nil
    )

    #expect(sender.requests.first?.destination == .recipient(recipient))
}

@Test
func sendServiceRejectsUnsupportedFeaturesBeforeCallingTheSender() async throws {
    let conversationID = try ConversationID(validating: "chat-guid")
    let phone = try RecipientHandle(type: .phone, value: "+15005550006")
    let stores = StubStores(
        conversation: fixtureConversation(id: conversationID, participants: [phone]),
        context: ConversationSendContext(
            conversationID: conversationID,
            providerGUID: conversationID.rawValue,
            accountID: "account-guid",
            accountLogin: nil,
            recipients: [phone]
        ),
        messages: []
    )
    let sender = FakeMessageSender.available(capabilities: .init(
        text: .available,
        media: .unsupported,
        nativeReply: .unsupported
    ))
    let mediaID = try MediaID(validating: "upload_fixture")
    let uploads = MemoryUploadStore(references: [
        mediaID: MediaReference(
            mediaID: mediaID,
            filename: "file.pdf",
            mimeType: "application/pdf",
            byteSize: 10,
            source: .upload
        )
    ])
    let service = MessageService(
        conversations: stores,
        messages: stores,
        sender: sender,
        media: MediaService(uploads: uploads, messagesMedia: NilMessageMediaStore()),
        allowlist: RecipientAllowlist(values: [phone.value])
    )

    await #expect(throws: RelayServiceError.unsupportedCapability(
        "Media sending is unsupported by the local sender."
    )) {
        try await service.send(
            SendMessageRequest(
                destination: .conversation(conversationID),
                content: MessageContent(text: nil, media: [SendMediaReference(mediaID: mediaID)]),
                replyTo: nil
            ),
            requestID: RequestID(validating: "request-media"),
            idempotencyKey: nil
        )
    }
    #expect(sender.requests.isEmpty)
}

@Test
func identicalIdempotencyRequestsReplayWithoutASecondDispatch() async throws {
    let stores = StubStores(conversation: nil, context: nil, messages: [])
    let sender = FakeMessageSender.available()
    let service = MessageService(
        conversations: stores,
        messages: stores,
        sender: sender,
        media: MediaService(uploads: MemoryUploadStore(), messagesMedia: NilMessageMediaStore()),
        allowlist: RecipientAllowlist(values: ["friend@example.com"])
    )
    let request = SendMessageRequest(
        destination: .recipient(try RecipientHandle(type: .email, value: "Friend@Example.COM")),
        content: MessageContent(text: "Hello", media: []),
        replyTo: nil
    )
    let firstID = try RequestID(validating: "first-request")
    let first = try await service.send(request, requestID: firstID, idempotencyKey: "duplicate-key")

    let replay = try await service.send(
        request,
        requestID: RequestID(validating: "second-request"),
        idempotencyKey: "duplicate-key"
    )
    #expect(replay == first)
    #expect(sender.requests.count == 1)
}

@Test
func sqliteSendRequestsPersistAcrossStoreInstancesAndRejectChangedPayloads() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-send-state-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("relay.db").path
    let firstID = try RequestID(validating: "first-request")
    let first = try SQLiteSendRequestStore(path: path)

    #expect(try await first.reserve(
        requestID: firstID,
        idempotencyKey: "client-key",
        fingerprint: "payload-a"
    ) == .created)
    let accepted = SendMessageResponse(
        requestID: firstID,
        status: .accepted,
        correlationStatus: .partial,
        conversationID: try ConversationID(validating: "persisted-conversation-guid"),
        messages: [MessageReceipt(
            messageID: try MessageID(validating: "provider-message-guid"),
            status: .sent
        )],
        media: [MediaReceipt(
            requestedMediaID: try MediaID(validating: "upload_fixture"),
            mediaID: nil,
            messageID: nil
        )],
        pollURL: "/v1/requests/first-request"
    )
    try await first.record(accepted)
    let correlation = SendCorrelationCriteria(
        checkpoint: OutgoingMessageCheckpoint(rowID: 42),
        destination: .recipient(try RecipientHandle(type: .email, value: "friend@example.com")),
        text: "Hello",
        media: [],
        replyToMessageID: nil,
        threadOriginatorMessageID: nil
    )
    try await first.recordCorrelation(correlation, requestID: firstID)

    let reopened = try SQLiteSendRequestStore(path: path)
    #expect(try await reopened.reserve(
        requestID: RequestID(validating: "second-request"),
        idempotencyKey: "client-key",
        fingerprint: "payload-a"
    ) == .replay(accepted))
    await #expect(throws: SendRequestStorageError.conflict(firstID)) {
        try await reopened.reserve(
            requestID: RequestID(validating: "third-request"),
            idempotencyKey: "client-key",
            fingerprint: "payload-b"
        )
    }
    #expect(try await reopened.response(requestID: firstID) == accepted)
    #expect(try await reopened.correlation(requestID: firstID) == correlation)
}

@Test
func sqliteSendRequestsMigrateExistingStateForCorrelationData() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-send-state-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("relay.db").path
    var database: OpaquePointer?
    #expect(sqlite3_open(path, &database) == SQLITE_OK)
    let oldSchema = """
        CREATE TABLE send_request (
            request_id TEXT PRIMARY KEY NOT NULL,
            idempotency_digest TEXT UNIQUE,
            fingerprint TEXT NOT NULL,
            status TEXT NOT NULL,
            message_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
    """
    #expect(sqlite3_exec(database, oldSchema, nil, nil, nil) == SQLITE_OK)
    let legacyInsert = """
        INSERT INTO send_request (
            request_id, idempotency_digest, fingerprint, status, message_id,
            created_at, updated_at
        ) VALUES (
            'legacy-request', NULL, 'legacy-payload', 'delivered',
            'legacy-message-guid', '2026-09-16T00:00:00Z', '2026-09-16T00:00:00Z'
        )
        """
    #expect(sqlite3_exec(database, legacyInsert, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)

    let store = try SQLiteSendRequestStore(path: path)
    let legacy = try #require(await store.response(
        requestID: RequestID(validating: "legacy-request")
    ))
    #expect(legacy.correlationStatus == .complete)
    #expect(legacy.messages == [MessageReceipt(
        messageID: try MessageID(validating: "legacy-message-guid"),
        status: .delivered
    )])
    let requestID = try RequestID(validating: "migration-request")
    #expect(try await store.reserve(
        requestID: requestID,
        idempotencyKey: nil,
        fingerprint: "payload"
    ) == .created)
    let correlation = SendCorrelationCriteria(
        checkpoint: OutgoingMessageCheckpoint(rowID: 12),
        destination: .recipient(try RecipientHandle(type: .email, value: "friend@example.com")),
        text: "Migrated",
        media: [],
        replyToMessageID: nil,
        threadOriginatorMessageID: nil
    )
    try await store.recordCorrelation(correlation, requestID: requestID)

    #expect(try await store.correlation(requestID: requestID) == correlation)
}

@Test
func sendServiceIdentifiesTheProviderMessageBeforeReleasingTheSend() async throws {
    let conversationID = try ConversationID(validating: "chat-guid")
    let messageID = try MessageID(validating: "provider-message-guid")
    let recipient = try RecipientHandle(type: .email, value: "friend@example.com")
    let outgoing = Message(
        id: messageID,
        providerGUID: messageID.rawValue,
        conversationID: conversationID,
        text: "Hello",
        sender: nil,
        isFromMe: true,
        createdAt: Timestamp(Date()),
        deliveryState: .delivered,
        readState: .unread,
        deliveredAt: Timestamp(Date()),
        readAt: nil,
        thread: nil,
        reactions: [],
        attachments: []
    )
    let stores = StubStores(conversation: nil, context: nil, messages: [outgoing])
    let correlator = StubSendCorrelator(
        checkpoint: OutgoingMessageCheckpoint(rowID: 91),
        outcomes: [.complete(SendCorrelationSnapshot(messages: [outgoing], media: []))]
    )
    let requests = InMemorySendRequestStore()
    let service = MessageService(
        conversations: stores,
        messages: stores,
        sender: FakeMessageSender.available(),
        media: MediaService(uploads: MemoryUploadStore(), messagesMedia: NilMessageMediaStore()),
        allowlist: RecipientAllowlist(values: [recipient.value]),
        sendRequests: requests,
        correlator: correlator,
        identificationTimeout: .milliseconds(20),
        identificationPollInterval: .milliseconds(1)
    )
    let requestID = try RequestID(validating: "correlated-request")

    let response = try await service.send(
        SendMessageRequest(
            destination: .recipient(recipient),
            content: MessageContent(text: "Hello", media: []),
            replyTo: nil
        ),
        requestID: requestID,
        idempotencyKey: "correlated-send"
    )

    #expect(response.messages.map(\.messageID) == [messageID])
    #expect(response.correlationStatus == .complete)
    #expect(response.status == MessageStatus.delivered)
    let criteria = try #require(await correlator.criteria.first)
    #expect(criteria.checkpoint.rowID == 91)
    #expect(criteria.destination == .recipient(recipient))
    #expect(criteria.text == "Hello")
    #expect(await requests.correlation(requestID: requestID) == criteria)
}

@Test
func sendIdentificationGateSerializesIdentificationWindows() async throws {
    let gate = SendIdentificationGate()
    let probe = IdentificationGateProbe()

    async let first: Void = gate.run {
        await probe.enter()
        try await Task.sleep(for: .milliseconds(20))
        await probe.leave()
    }
    async let second: Void = gate.run {
        await probe.enter()
        try await Task.sleep(for: .milliseconds(20))
        await probe.leave()
    }
    _ = try await (first, second)

    #expect(await probe.maximumActive == 1)
}

@Test
func pollingAReceiptRetriesProviderIdentification() async throws {
    let conversationID = try ConversationID(validating: "chat-guid")
    let messageID = try MessageID(validating: "late-provider-guid")
    let recipient = try RecipientHandle(type: .email, value: "friend@example.com")
    let outgoing = Message(
        id: messageID,
        providerGUID: messageID.rawValue,
        conversationID: conversationID,
        text: "Late row",
        sender: nil,
        isFromMe: true,
        createdAt: Timestamp(Date()),
        deliveryState: .sent,
        readState: .unread,
        deliveredAt: nil,
        readAt: nil,
        thread: nil,
        reactions: [],
        attachments: []
    )
    let stores = StubStores(conversation: nil, context: nil, messages: [outgoing])
    let correlator = StubSendCorrelator(
        checkpoint: OutgoingMessageCheckpoint(rowID: 100),
        outcomes: [
            .pending,
            .complete(SendCorrelationSnapshot(messages: [outgoing], media: [])),
        ]
    )
    let service = MessageService(
        conversations: stores,
        messages: stores,
        sender: FakeMessageSender.available(),
        media: MediaService(uploads: MemoryUploadStore(), messagesMedia: NilMessageMediaStore()),
        allowlist: RecipientAllowlist(values: [recipient.value]),
        correlator: correlator,
        identificationTimeout: .zero
    )
    let requestID = try RequestID(validating: "late-correlation-request")
    let accepted = try await service.send(
        SendMessageRequest(
            destination: .recipient(recipient),
            content: MessageContent(text: "Late row", media: []),
            replyTo: nil
        ),
        requestID: requestID,
        idempotencyKey: nil
    )
    #expect(accepted.messages.isEmpty)
    #expect(accepted.correlationStatus == .pending)
    #expect(accepted.status == .accepted)

    let reconciled = try await service.request(id: requestID)

    #expect(reconciled.messages.map(\.messageID) == [messageID])
    #expect(reconciled.correlationStatus == .complete)
    #expect(reconciled.status == .sent)
}

@Test
func pollingCompletesASplitTextAndMediaReceiptWithoutLosingTheFirstMessage() async throws {
    let conversationID = try ConversationID(validating: "chat-guid")
    let textMessageID = try MessageID(validating: "split-text-guid")
    let mediaMessageID = try MessageID(validating: "split-media-guid")
    let requestedMediaID = try MediaID(validating: "upload_split")
    let providerMediaID = try MediaID(validating: "provider-media-guid")
    let recipient = try RecipientHandle(type: .email, value: "friend@example.com")
    let textMessage = Message(
        id: textMessageID,
        providerGUID: textMessageID.rawValue,
        conversationID: conversationID,
        text: "Split send",
        sender: nil,
        isFromMe: true,
        createdAt: Timestamp(Date()),
        deliveryState: .delivered,
        readState: .unread,
        deliveredAt: Timestamp(Date()),
        readAt: nil,
        thread: nil,
        reactions: [],
        attachments: []
    )
    let attachment = MediaReference(
        mediaID: providerMediaID,
        filename: "split.jpg",
        mimeType: "image/jpeg",
        byteSize: 10,
        source: .messages
    )
    let mediaMessage = Message(
        id: mediaMessageID,
        providerGUID: mediaMessageID.rawValue,
        conversationID: conversationID,
        text: nil,
        sender: nil,
        isFromMe: true,
        createdAt: Timestamp(Date()),
        deliveryState: .sent,
        readState: .unread,
        deliveredAt: nil,
        readAt: nil,
        thread: nil,
        reactions: [],
        attachments: [attachment]
    )
    let stores = StubStores(
        conversation: fixtureConversation(id: conversationID, participants: [recipient]),
        context: ConversationSendContext(
            conversationID: conversationID,
            providerGUID: conversationID.rawValue,
            accountID: "account-guid",
            accountLogin: nil,
            recipients: [recipient]
        ),
        messages: [mediaMessage, textMessage]
    )
    let pendingMedia = MediaReceipt(
        requestedMediaID: requestedMediaID,
        mediaID: nil,
        messageID: nil
    )
    let matchedMedia = MediaReceipt(
        requestedMediaID: requestedMediaID,
        mediaID: providerMediaID,
        messageID: mediaMessageID
    )
    let correlator = StubSendCorrelator(
        checkpoint: OutgoingMessageCheckpoint(rowID: 200),
        outcomes: [
            .partial(SendCorrelationSnapshot(
                messages: [textMessage],
                media: [pendingMedia]
            )),
            .complete(SendCorrelationSnapshot(
                messages: [textMessage, mediaMessage],
                media: [matchedMedia]
            )),
        ]
    )
    let uploads = MemoryUploadStore(references: [
        requestedMediaID: MediaReference(
            mediaID: requestedMediaID,
            filename: "split.jpg",
            mimeType: "image/jpeg",
            byteSize: 10,
            source: .upload
        )
    ])
    let service = MessageService(
        conversations: stores,
        messages: stores,
        sender: FakeMessageSender.available(),
        media: MediaService(uploads: uploads, messagesMedia: NilMessageMediaStore()),
        allowlist: RecipientAllowlist(values: [recipient.value]),
        correlator: correlator,
        identificationTimeout: .zero
    )
    let requestID = try RequestID(validating: "split-request")

    let partial = try await service.send(
        SendMessageRequest(
            destination: .conversation(conversationID),
            content: MessageContent(
                text: "Split send",
                media: [SendMediaReference(mediaID: requestedMediaID)]
            ),
            replyTo: nil
        ),
        requestID: requestID,
        idempotencyKey: nil
    )
    #expect(partial.correlationStatus == .partial)
    #expect(partial.conversationID == conversationID)
    #expect(partial.messages.map(\.messageID) == [textMessageID])
    #expect(partial.media == [pendingMedia])

    let complete = try await service.request(id: requestID)

    #expect(complete.correlationStatus == .complete)
    #expect(complete.conversationID == conversationID)
    #expect(complete.messages.map(\.messageID) == [textMessageID, mediaMessageID])
    #expect(complete.media == [matchedMedia])
    #expect(complete.status == .sent)
}

@Test
func mediaServiceRejectsUnsafeNamesMIMEsAndOversizedUploads() async throws {
    let service = MediaService(
        uploads: MemoryUploadStore(),
        messagesMedia: NilMessageMediaStore(),
        policy: MediaPolicy(maximumBytes: 4, maximumFilenameBytes: 20)
    )

    await #expect(throws: RelayServiceError.unsafeMedia("The filename is unsafe.")) {
        try await service.upload(filename: "../photo.jpg", mimeType: "image/jpeg", data: Data([1]))
    }
    await #expect(throws: RelayServiceError.unsafeMedia("The filename is unsafe.")) {
        try await service.upload(filename: "photo\".jpg", mimeType: "image/jpeg", data: Data([1]))
    }
    await #expect(throws: RelayServiceError.unsafeMedia("The media file is empty.")) {
        try await service.upload(filename: "photo.jpg", mimeType: "image/jpeg", data: Data())
    }
    await #expect(throws: RelayServiceError.unsafeMedia("The MIME type is not allowed.")) {
        try await service.upload(filename: "file.zip", mimeType: "application/zip", data: Data([1]))
    }
    await #expect(throws: RelayServiceError.mediaTooLarge(maximumBytes: 4)) {
        try await service.upload(filename: "photo.jpg", mimeType: "image/jpeg", data: Data(repeating: 1, count: 5))
    }
}

@Test
func mediaFileStoreRejectsMetadataForAnotherMediaID() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-media-metadata-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MediaFileStore(directory: directory)
    let saved = try await store.save(MediaUpload(
        filename: "notes.txt",
        mimeType: "text/plain",
        data: Data("fixture".utf8)
    ))
    let metadataURL = directory
        .appendingPathComponent(saved.mediaID.rawValue)
        .appendingPathComponent("metadata.json")
    let differentID = "upload_\(UUID().uuidString.lowercased())"
    let tampered = """
        {"id":"\(differentID)","filename":"notes.txt","mimeType":"text/plain","byteSize":7}
        """
    try Data(tampered.utf8).write(to: metadataURL, options: .atomic)

    #expect(try await store.reference(id: saved.mediaID) == nil)
}

private final class StubStores: ConversationStoring, MessageStoring, @unchecked Sendable {
    let conversationValue: Conversation?
    let contextValue: ConversationSendContext?
    let messageValues: [Message]

    init(conversation: Conversation?, context: ConversationSendContext?, messages: [Message]) {
        conversationValue = conversation
        contextValue = context
        messageValues = messages
    }

    func listConversations(options: ConversationListOptions) async throws -> PaginatedResponse<Conversation> {
        PaginatedResponse(items: conversationValue.map { [$0] } ?? [], nextCursor: nil, hasMore: false)
    }

    func conversation(id: ConversationID) async throws -> Conversation? {
        conversationValue?.id == id ? conversationValue : nil
    }

    func sendContext(id: ConversationID) async throws -> ConversationSendContext? {
        contextValue?.conversationID == id ? contextValue : nil
    }

    func sendContexts(
        matchingExactParticipants participants: [RecipientHandle]
    ) async throws -> [ConversationSendContext] {
        guard let contextValue else { return [] }
        let expected = Set(participants.map { "\($0.type.rawValue)\u{0}\($0.value)" })
        let actual = Set(contextValue.recipients.map { "\($0.type.rawValue)\u{0}\($0.value)" })
        return expected == actual ? [contextValue] : []
    }

    func listMessages(
        conversationID: ConversationID,
        options: MessageListOptions
    ) async throws -> PaginatedResponse<Message> {
        PaginatedResponse(
            items: messageValues.filter { $0.conversationID == conversationID },
            nextCursor: nil,
            hasMore: false
        )
    }

    func message(id: MessageID) async throws -> Message? {
        messageValues.first { $0.id == id }
    }
}

private actor StubSendCorrelator: SendCorrelating {
    let checkpointValue: OutgoingMessageCheckpoint
    var outcomes: [SendCorrelationOutcome]
    var criteria: [SendCorrelationCriteria] = []

    init(checkpoint: OutgoingMessageCheckpoint, outcomes: [SendCorrelationOutcome]) {
        checkpointValue = checkpoint
        self.outcomes = outcomes
    }

    func checkpoint() -> OutgoingMessageCheckpoint { checkpointValue }

    func correlate(_ criteria: SendCorrelationCriteria) -> SendCorrelationOutcome {
        self.criteria.append(criteria)
        return outcomes.isEmpty ? .pending : outcomes.removeFirst()
    }
}

private actor IdentificationGateProbe {
    private(set) var maximumActive = 0
    private var active = 0

    func enter() {
        active += 1
        maximumActive = max(maximumActive, active)
    }

    func leave() {
        active -= 1
    }
}

private actor MemoryUploadStore: UploadedMediaStoring {
    private var references: [MediaID: MediaReference]

    init(references: [MediaID: MediaReference] = [:]) {
        self.references = references
    }

    func save(_ upload: MediaUpload) async throws -> MediaReference {
        let id = try MediaID(validating: "upload_test")
        let reference = MediaReference(
            mediaID: id,
            filename: upload.filename,
            mimeType: upload.mimeType,
            byteSize: Int64(upload.data.count),
            source: .upload
        )
        references[id] = reference
        return reference
    }

    func reference(id: MediaID) async throws -> MediaReference? { references[id] }
    func readable(id: MediaID) async throws -> ReadableMedia? { nil }
    func outbound(id: MediaID) async throws -> OutboundMedia? {
        references[id].map {
            OutboundMedia(
                reference: $0,
                fileURL: URL(fileURLWithPath: "/synthetic/\($0.filename ?? id.rawValue)")
            )
        }
    }
}

private struct NilMessageMediaStore: MessageMediaStoring {
    func media(id: MediaID) async throws -> ReadableMedia? { nil }
}

private actor RecordingTypingLeaseStopper: TypingLeaseStopping {
    private(set) var stopCount = 0

    func stopActiveTyping() {
        stopCount += 1
    }
}

private func fixtureConversation(
    id: ConversationID,
    participants: [RecipientHandle]
) -> Conversation {
    Conversation(
        id: id,
        providerGUID: id.rawValue,
        identifier: nil,
        displayName: nil,
        service: "iMessage",
        isGroup: participants.count > 1,
        participants: participants,
        unreadCount: 0,
        lastMessageAt: nil
    )
}

private func fixtureMessage(
    id: MessageID,
    conversationID: ConversationID,
    thread: ThreadReference? = nil
) -> Message {
    Message(
        id: id,
        providerGUID: id.rawValue,
        conversationID: conversationID,
        text: "Reply target",
        sender: nil,
        isFromMe: false,
        createdAt: nil,
        deliveryState: .unknown,
        readState: .read,
        deliveredAt: nil,
        readAt: nil,
        thread: thread,
        reactions: [],
        attachments: []
    )
}
