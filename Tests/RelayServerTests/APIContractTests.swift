import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import RelayCore
import Testing

@testable import RelayServer

@Test
func statusAndSenderRoutesReportTheRealFakeCapabilitiesWithoutSending() async throws {
    let harness = ServerTestHarness(sender: FakeMessageSender.available(capabilities: .init(
        text: .available,
        media: .unsupported,
        nativeReply: .unsupported
    )))
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let statusResponse = try await client.execute(
            uri: "/v1/status",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(statusResponse.status == .ok)
        let status = try RelayJSON.decoder.decode(
            ServiceStatus.self,
            from: Data(statusResponse.body.readableBytesView)
        )
        #expect(status.healthy)
        #expect(status.database.identity == "fixture-database")
        #expect(status.sender.capabilities.media == .unsupported)
        #expect(status.sender.capabilities.groupCreation == .unsupported)

        let senderResponse = try await client.execute(
            uri: "/v1/sender",
            method: .get,
            headers: authorizationHeaders()
        )
        let sender = try RelayJSON.decoder.decode(
            Sender.self,
            from: Data(senderResponse.body.readableBytesView)
        )
        #expect(sender.availability == .available)
        #expect(sender.permissions == .unknown)
        #expect(harness.sender.requests.isEmpty)
    }
}

@Test
func conversationAndMessageRoutesUseStableProviderIdentifiers() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let conversations = try await client.execute(
            uri: "/v1/conversations?limit=20&unread_only=true",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(conversations.status == .ok)
        let conversationPage = try RelayJSON.decoder.decode(
            PaginatedResponse<Conversation>.self,
            from: Data(conversations.body.readableBytesView)
        )
        #expect(conversationPage.items.map(\.id.rawValue) == ["chat-guid"])

        let detail = try await client.execute(
            uri: "/v1/conversations/chat-guid",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(try RelayJSON.decoder.decode(
            Conversation.self,
            from: Data(detail.body.readableBytesView)
        ).providerGUID == "chat-guid")

        let history = try await client.execute(
            uri: "/v1/conversations/chat-guid/messages?include_attachments=true&q=reply&search_mode=contains",
            method: .get,
            headers: authorizationHeaders()
        )
        let page = try RelayJSON.decoder.decode(
            PaginatedResponse<Message>.self,
            from: Data(history.body.readableBytesView)
        )
        let nested = try #require(page.items.first)
        #expect(nested.thread?.replyToMessageID?.rawValue == "message-parent")
        #expect(nested.thread?.threadOriginatorMessageID?.rawValue == "message-root")
        #expect(nested.reactions.map(\.kind) == [.like])

        let message = try await client.execute(
            uri: "/v1/messages/message-root",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(message.status == .ok)

        let obsolete = try await client.execute(
            uri: "/chats",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(obsolete.status == .notFound)
        #expect(try errorBody(obsolete.body).code == .notFound)
    }
}

@Test
func markingAConversationReadIsIdempotentAndDatabaseConfirmed() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let applied = try await client.execute(
            uri: "/v1/conversations/chat-guid/read",
            method: .put,
            headers: authorizationHeaders()
        )
        #expect(applied.status == .ok)
        let appliedObject = try jsonObject(applied.body)
        #expect(appliedObject["conversation_id"] as? String == "chat-guid")
        #expect(appliedObject["status"] as? String == "applied")

        let unchanged = try await client.execute(
            uri: "/v1/conversations/chat-guid/read",
            method: .put,
            headers: authorizationHeaders()
        )
        #expect(unchanged.status == .ok)
        #expect(try jsonObject(unchanged.body)["status"] as? String == "unchanged")
        #expect(harness.readWriter.requests == [ConversationReadWriteRequest(
            conversationGUID: "chat-guid",
            anchorMessageGUID: "message-nested"
        )])
    }
}

@Test
func typingIndicatorUsesARefreshableConversationLease() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        for _ in 0..<2 {
            let active = try await client.execute(
                uri: "/v1/conversations/chat-guid/typing",
                method: .put,
                headers: authorizationHeaders()
            )
            #expect(active.status == .ok)
            let object = try jsonObject(active.body)
            #expect(object["conversation_id"] as? String == "chat-guid")
            #expect(object["status"] as? String == "active")
            #expect(object["expires_at"] is String)
        }

        for _ in 0..<2 {
            let inactive = try await client.execute(
                uri: "/v1/conversations/chat-guid/typing",
                method: .delete,
                headers: authorizationHeaders()
            )
            #expect(inactive.status == .ok)
            let object = try jsonObject(inactive.body)
            #expect(object["conversation_id"] as? String == "chat-guid")
            #expect(object["status"] as? String == "inactive")
            #expect(object["expires_at"] == nil)
        }
        let nativeRequest = ConversationTypingWriteRequest(
            conversationGUID: "chat-guid",
            anchorMessageGUID: "message-nested",
            isGroup: false
        )
        #expect(harness.typingWriter.calls == [
            .start(nativeRequest),
            .start(nativeRequest),
            .stop(nativeRequest),
        ])
    }
}

@Test
func accessibilityWritesStopTheActiveTypingLeaseFirst() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        _ = try await client.execute(
            uri: "/v1/conversations/chat-guid/typing",
            method: .put,
            headers: authorizationHeaders()
        )
        let read = try await client.execute(
            uri: "/v1/conversations/chat-guid/read",
            method: .put,
            headers: authorizationHeaders()
        )
        #expect(read.status == .ok)

        _ = try await client.execute(
            uri: "/v1/conversations/chat-guid/typing",
            method: .put,
            headers: authorizationHeaders()
        )
        let reaction = try await client.execute(
            uri: "/v1/messages/message-root/reaction",
            method: .put,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: #"{"reaction":"love"}"#)
        )
        #expect(reaction.status == .ok)

        let request = ConversationTypingWriteRequest(
            conversationGUID: "chat-guid",
            anchorMessageGUID: "message-nested",
            isGroup: false
        )
        #expect(harness.typingWriter.calls == [
            .start(request), .stop(request),
            .start(request), .stop(request),
        ])
    }
}

@Test
func conversationListNormalizesTheParticipantFilter() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())
    let expected = try RecipientHandle.direct(value: "Friend@Example.COM")

    try await app.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/conversations?participant=Friend%40Example.COM",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(response.status == .ok)
        #expect(harness.store.lastConversationListOptions?.participant == expected)
    }
}

@Test
func encodedProviderGUIDPathResolvesTheRawConversationID() async throws {
    let id = try ConversationID(validating: "any;-;recipient@example.com")
    let recipient = try RecipientHandle(type: .email, value: "recipient@example.com")
    let conversation = Conversation(
        id: id,
        providerGUID: id.rawValue,
        identifier: recipient.value,
        displayName: nil,
        service: "iMessage",
        isGroup: false,
        participants: [recipient],
        unreadCount: 0,
        lastMessageAt: nil
    )
    let context = ConversationSendContext(
        conversationID: id,
        providerGUID: id.rawValue,
        accountID: "account-guid",
        accountLogin: nil,
        recipients: [recipient]
    )
    let message = Message(
        id: try MessageID(validating: "message-guid"),
        providerGUID: "message-guid",
        conversationID: id,
        text: "Encoded path fixture",
        sender: recipient,
        isFromMe: false,
        createdAt: nil,
        deliveryState: .unknown,
        readState: .unknown,
        deliveredAt: nil,
        readAt: nil,
        thread: nil,
        reactions: [],
        attachments: []
    )
    let harness = ServerTestHarness(store: APIStore(
        conversation: conversation,
        context: context,
        messages: [message]
    ))
    let app = Application(router: harness.router())
    let encodedID = "any%3B-%3Brecipient%40example.com"

    try await app.test(.router) { client in
        let detail = try await client.execute(
            uri: "/v1/conversations/\(encodedID)",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(detail.status == .ok)

        let history = try await client.execute(
            uri: "/v1/conversations/\(encodedID)/messages",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(history.status == .ok)
    }
}

@Test
func postMessagesReturnsCorrelationDataAndRecordsTheCompleteDispatch() async throws {
    let acceptedID = try MessageID(validating: "accepted-message-guid")
    let sender = FakeMessageSender(
        sender: await FakeMessageSender.available().status(),
        outcome: .result(.init(messageID: acceptedID, status: .sent))
    )
    let harness = ServerTestHarness(sender: sender)
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: #"{"conversation_id":"chat-guid","text":"Synthetic only"}"#)
        )
        #expect(response.status == .accepted)
        let responseObject = try jsonObject(response.body)
        #expect(responseObject["message_id"] == nil)
        #expect(responseObject["correlation_status"] as? String == "complete")
        let result = try RelayJSON.decoder.decode(
            SendMessageResponse.self,
            from: Data(response.body.readableBytesView)
        )
        #expect(result.messages == [MessageReceipt(messageID: acceptedID, status: .sent)])
        #expect(result.media.isEmpty)
        #expect(result.correlationStatus == .complete)
        #expect(result.status == .sent)
        #expect(result.conversationID?.rawValue == "chat-guid")
        #expect(result.pollURL == "/v1/requests/\(result.requestID.rawValue)")
        #expect(response.headers[.init("x-request-id")!] == result.requestID.rawValue)
        #expect(sender.requests.first?.conversationContext?.accountID == "account-guid")
        #expect(sender.requests.first?.text == "Synthetic only")

        let pollURL = try #require(result.pollURL)
        let tracked = try await client.execute(
            uri: pollURL,
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(tracked.status == .ok)
        #expect(try RelayJSON.decoder.decode(
            SendMessageResponse.self,
            from: Data(tracked.body.readableBytesView)
        ) == result)
    }
}

@Test
func postMessagesStartsAGroupWithNormalizedAllowlistedParticipants() async throws {
    let harness = ServerTestHarness(
        allowedRecipients: ["friend@example.com", "+15005550006"]
    )
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([
                .contentType: "application/json",
                .init("idempotency-key")!: "group-contract-1",
            ]),
            body: ByteBuffer(string: """
                {"participants":["Friend@Example.COM","+1 500 555 0006"],"text":"Group hello"}
                """)
        )
        #expect(response.status == .accepted)
        let result = try RelayJSON.decoder.decode(
            SendMessageResponse.self,
            from: Data(response.body.readableBytesView)
        )
        #expect(result.conversationID == nil)
        #expect(result.correlationStatus == .pending)
        #expect(harness.sender.requests.count == 1)
        #expect(harness.sender.requests.first?.destination == .participants([
            try RecipientHandle(type: .email, value: "Friend@Example.COM"),
            try RecipientHandle(type: .phone, value: "+1 500 555 0006"),
        ]))

        let replay = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([
                .contentType: "application/json",
                .init("idempotency-key")!: "group-contract-1",
            ]),
            body: ByteBuffer(string: """
                {"participants":["+15005550006","friend@example.com"],"text":"Group hello"}
                """)
        )
        #expect(replay.status == .accepted)
        #expect(Data(replay.body.readableBytesView) == Data(response.body.readableBytesView))
        #expect(harness.sender.requests.count == 1)

        let media = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: """
                {"participants":["friend@example.com","+15005550006"],"text":"caption","media":[{"media_id":"upload_missing"}]}
                """)
        )
        #expect(media.status == .notImplemented)
        #expect(try errorBody(media.body).code == .unsupportedCapability)
        #expect(harness.sender.requests.count == 1)
    }
}

@Test
func postMessagesReusesOneExactParticipantConversation() async throws {
    let participants = [
        try RecipientHandle.direct(value: "friend@example.com"),
        try RecipientHandle.direct(value: "+15005550006"),
    ]
    let groupID = try ConversationID(validating: "iMessage;+;existing-group")
    let groupContext = ConversationSendContext(
        conversationID: groupID,
        providerGUID: groupID.rawValue,
        accountID: "group-account-guid",
        accountLogin: "sender@example.com",
        recipients: participants
    )
    let harness = ServerTestHarness(
        store: APIStore(matchingContexts: [groupContext]),
        sender: .available(capabilities: .init(
            text: .available,
            media: .available,
            nativeReply: .available,
            reactions: .available,
            groupCreation: .unsupported
        )),
        allowedRecipients: participants.map(\.value)
    )
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: """
                {"participants":["+1 500 555 0006","FRIEND@EXAMPLE.COM"],"text":"Existing group"}
                """)
        )
        #expect(response.status == .accepted)
        let result = try RelayJSON.decoder.decode(
            SendMessageResponse.self,
            from: Data(response.body.readableBytesView)
        )
        #expect(result.conversationID == groupID)
        #expect(harness.sender.requests.first?.destination == .conversation(groupID))
        #expect(harness.sender.requests.first?.conversationContext?.accountID == "group-account-guid")
    }
}

@Test
func messageReactionUsesOneWholeMessageResource() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let setResponse = try await client.execute(
            uri: "/v1/messages/message-root/reaction",
            method: .put,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: #"{"reaction":"love"}"#)
        )
        #expect(setResponse.status == .ok)
        let setObject = try jsonObject(setResponse.body)
        #expect(setObject["message_id"] as? String == "message-root")
        #expect(setObject["status"] as? String == "applied")
        #expect(setObject["reaction"] as? String == "love")
        #expect(setObject["part_index"] == nil)

        let repeatedSet = try await client.execute(
            uri: "/v1/messages/message-root/reaction",
            method: .put,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: #"{"reaction":"love"}"#)
        )
        #expect(repeatedSet.status == .ok)
        #expect(try jsonObject(repeatedSet.body)["status"] as? String == "unchanged")

        let clearResponse = try await client.execute(
            uri: "/v1/messages/message-root/reaction",
            method: .delete,
            headers: authorizationHeaders()
        )
        #expect(clearResponse.status == .ok)
        let clearObject = try jsonObject(clearResponse.body)
        #expect(clearObject["message_id"] as? String == "message-root")
        #expect(clearObject["status"] as? String == "applied")
        #expect(clearObject["reaction"] is NSNull)
        #expect(clearObject["part_index"] == nil)

        let repeatedClear = try await client.execute(
            uri: "/v1/messages/message-root/reaction",
            method: .delete,
            headers: authorizationHeaders()
        )
        #expect(repeatedClear.status == .ok)
        #expect(try jsonObject(repeatedClear.body)["status"] as? String == "unchanged")
        #expect(harness.reactionWriter.requests.count == 2)
    }
}

@Test
func messageReactionRejectsUnknownReactionNames() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/messages/message-root/reaction",
            method: .put,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: #"{"reaction":"fire"}"#)
        )

        #expect(response.status == .unprocessableContent)
        let error = try errorBody(response.body)
        #expect(error.code == .invalidRequest)
        #expect(error.fieldDetails == [APIFieldError(
            field: "reaction",
            message: "Use love, like, dislike, laugh, emphasis, or question."
        )])
        #expect(harness.reactionWriter.requests.isEmpty)
    }
}

@Test
func mediaUsesUploadThenReferenceAndNeverReturnsAPath() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())
    let bytes = Data("synthetic media".utf8)

    try await app.test(.router) { client in
        let upload = try await client.execute(
            uri: "/v1/media",
            method: .post,
            headers: authorizationHeaders([
                .contentType: "text/plain",
                .init("x-filename")!: "notes.txt",
            ]),
            body: ByteBuffer(bytes: bytes)
        )
        #expect(upload.status == .created)
        let uploaded = try RelayJSON.decoder.decode(
            UploadMediaResponse.self,
            from: Data(upload.body.readableBytesView)
        )
        #expect(uploaded.media.source == .upload)
        #expect(uploaded.media.filename == "notes.txt")
        #expect(uploaded.media.byteSize == Int64(bytes.count))
        let uploadBody = Data(upload.body.readableBytesView)
        #expect(String(data: uploadBody, encoding: .utf8)?.contains(harness.config.mediaDirectory) == false)

        let metadata = try await client.execute(
            uri: "/v1/media/\(uploaded.media.mediaID.rawValue)",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(metadata.status == .ok)
        #expect(try RelayJSON.decoder.decode(
            MediaReference.self,
            from: Data(metadata.body.readableBytesView)
        ) == uploaded.media)

        let download = try await client.execute(
            uri: "/v1/media/\(uploaded.media.mediaID.rawValue)?download=true",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(download.status == .ok)
        #expect(download.headers[.contentType] == "text/plain")
        #expect(Data(download.body.readableBytesView) == bytes)

        let send = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: """
                {"to":"friend@example.com","media":[{"media_id":"\(uploaded.media.mediaID.rawValue)"}]}
                """)
        )
        #expect(send.status == .accepted)
        let dispatched = try #require(harness.sender.requests.last?.media.first)
        #expect(dispatched.reference == uploaded.media)
        #expect(dispatched.fileURL.lastPathComponent == "notes.txt")
        #expect(try Data(contentsOf: dispatched.fileURL) == bytes)
    }
}

@Test
func downloadFilenameCannotInjectResponseHeaders() {
    #expect(safeDownloadFilename("report\"\r\nX-Injected: yes.txt") == "report___X-Injected_ yes.txt")
    #expect(safeDownloadFilename("résumé.pdf") == "resume.pdf")
    #expect(safeDownloadFilename("") == "download")
}
