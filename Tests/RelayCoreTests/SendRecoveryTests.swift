import Foundation
import Testing

@testable import RelayCore

@Test
func idempotentReplayDoesNotRequireTheOriginalUpload() async throws {
    let mediaID = try MediaID(validating: "upload_missing")
    let recipient = try RecipientHandle(type: .email, value: "friend@example.com")
    let conversationID = try ConversationID(validating: "media-chat")
    let anchor = fixtureMessage(
        id: try MessageID(validating: "media-anchor"), conversationID: conversationID
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
        messages: [anchor]
    )
    let request = SendMessageRequest(
        destination: .conversation(conversationID),
        content: MessageContent(text: "Hello", media: [SendMediaReference(mediaID: mediaID)]),
        replyTo: nil
    )
    let uploads = MemoryUploadStore(references: [mediaID: MediaReference(
        mediaID: mediaID, filename: "photo.jpg", mimeType: "image/jpeg", byteSize: 10, source: .upload
    )])
    let requests = InMemorySendRequestStore()
    let sender = FakeMessageSender.available()
    let service = MessageService(
        conversations: stores,
        messages: stores,
        sender: sender,
        media: MediaService(uploads: uploads, messagesMedia: NilMessageMediaStore()),
        allowlist: RecipientAllowlist(values: [recipient.value]),
        sendRequests: requests
    )
    let first = try await service.send(
        request, requestID: RequestID(validating: "original-media-request"), idempotencyKey: "media-key"
    )
    await uploads.remove(id: mediaID)

    let replay = try await service.send(
        request,
        requestID: RequestID(validating: "replayed-media-request"),
        idempotencyKey: "media-key"
    )
    #expect(replay == first)
    #expect(sender.requests.count == 1)
    await #expect(throws: RelayServiceError.duplicateRequest(first.requestID)) {
        try await service.send(
            SendMessageRequest(
                destination: .conversation(conversationID),
                content: MessageContent(text: "Changed", media: [SendMediaReference(mediaID: mediaID)]),
                replyTo: nil
            ),
            requestID: RequestID(validating: "conflicting-media-request"),
            idempotencyKey: "media-key"
        )
    }
}

@Test
func persistedInterruptedSendRetainsItsCorrelationForPolling() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-send-recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("relay.db").path
    let requestID = try RequestID(validating: "interrupted-correlated-request")
    let first = try SQLiteSendRequestStore(path: path)
    #expect(try await first.reserve(
        requestID: requestID, idempotencyKey: "recover-key", fingerprint: "payload"
    ) == .created)
    let recipient = try RecipientHandle(type: .email, value: "friend@example.com")
    let correlation = SendCorrelationCriteria(
        checkpoint: OutgoingMessageCheckpoint(rowID: 42),
        destination: .recipient(recipient),
        text: "Hello",
        media: [],
        replyToMessageID: nil,
        threadOriginatorMessageID: nil
    )
    try await first.recordCorrelation(correlation, requestID: requestID)

    let reopened = try SQLiteSendRequestStore(path: path)
    let pending = try #require(await reopened.response(requestID: requestID))
    #expect(pending.status == .resultUnknown)
    #expect(pending.correlationStatus == .pending)
    let message = fixtureMessage(
        id: try MessageID(validating: "recovered-message"),
        conversationID: try ConversationID(validating: "recovered-chat")
    )
    let stores = StubStores(conversation: nil, context: nil, messages: [message])
    let service = MessageService(
        conversations: stores,
        messages: stores,
        sender: FakeMessageSender.available(),
        media: MediaService(uploads: MemoryUploadStore(), messagesMedia: NilMessageMediaStore()),
        allowlist: RecipientAllowlist(values: [recipient.value]),
        sendRequests: reopened,
        correlator: StubSendCorrelator(
            checkpoint: OutgoingMessageCheckpoint(rowID: 42),
            outcomes: [.complete(SendCorrelationSnapshot(messages: [message], media: []))]
        )
    )
    let recovered = try await service.request(id: requestID)
    #expect(recovered.correlationStatus == .complete)
    #expect(recovered.messages.map(\.messageID) == [message.id])
}
