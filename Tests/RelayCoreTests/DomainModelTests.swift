import Foundation
import Testing

@testable import RelayCore

@Test
func stableIdentifiersEncodeAsStringsAndRejectEmptyInput() throws {
    let id = try ConversationID(validating: "iMessage;-;+12025550100")
    let data = try JSONEncoder().encode(id)

    #expect(String(data: data, encoding: .utf8) == #""iMessage;-;+12025550100""#)
    #expect(try JSONDecoder().decode(ConversationID.self, from: data) == id)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(MessageID.self, from: Data(#""""#.utf8))
    }
}

@Test
func recipientHandlesNormalizeWithoutLosingDisplayInput() throws {
    let phone = try RecipientHandle(type: .phone, value: "+1 500 555 0006")
    let email = try RecipientHandle(type: .email, value: " Person@Example.COM ")

    #expect(phone.value == "+15005550006")
    #expect(phone.displayValue == "+1 500 555 0006")
    #expect(email.value == "person@example.com")
    #expect(email.displayValue == "Person@Example.COM")
    #expect(phone.matches(try RecipientHandle(type: .phone, value: "+1-500-555-0006")))
    #expect(email.matches(try RecipientHandle(type: .email, value: "PERSON@example.com")))
}

@Test
func recipientValidationRejectsMislabeledAndMalformedValues() {
    #expect(throws: RecipientHandle.ValidationError.self) {
        try RecipientHandle(type: .phone, value: "person@example.com")
    }
    #expect(throws: RecipientHandle.ValidationError.self) {
        try RecipientHandle(type: .email, value: "not-an-email")
    }
    #expect(throws: RecipientHandle.ValidationError.self) {
        try RecipientHandle(type: .phone, value: "+1234567890123456")
    }
}

@Test
func messageJSONKeepsImmediateReplyAndThreadRootSeparate() throws {
    let parent = try MessageID(validating: "parent-guid")
    let root = try MessageID(validating: "root-guid")
    let message = Message(
        id: try MessageID(validating: "message-guid"),
        providerGUID: "message-guid",
        conversationID: try ConversationID(validating: "chat-guid"),
        text: nil,
        sender: nil,
        isFromMe: true,
        createdAt: nil,
        deliveryState: .sent,
        readState: .unknown,
        deliveredAt: nil,
        readAt: nil,
        thread: ThreadReference(
            replyToMessageID: parent,
            threadOriginatorMessageID: root
        ),
        parts: [
            .attachment(index: 0, attachment: nil),
            .text(index: 1, text: "Caption"),
        ],
        reactions: [],
        attachments: []
    )

    let object = try jsonObject(message)
    let thread = try #require(object["thread"] as? [String: Any])
    #expect(thread["reply_to_message_id"] as? String == "parent-guid")
    #expect(thread["thread_originator_message_id"] as? String == "root-guid")
    #expect(object["text"] is NSNull)
    #expect(object["conversation_id"] as? String == "chat-guid")
    #expect(object["is_from_me"] as? Bool == true)
    let parts = try #require(object["parts"] as? [[String: Any]])
    #expect(parts.count == 2)
    #expect(parts[0]["index"] as? Int == 0)
    #expect(parts[0]["type"] as? String == "attachment")
    #expect(parts[0]["attachment"] is NSNull)
    #expect(parts[1]["index"] as? Int == 1)
    #expect(parts[1]["type"] as? String == "text")
    #expect(parts[1]["text"] as? String == "Caption")
}

@Test
func sendRequestUsesExactlyOneDestinationShape() throws {
    let direct = try RelayJSON.decoder.decode(
        SendMessageRequest.self,
        from: Data(#"{"to":"+1 500 555 0006","text":"Hello"}"#.utf8)
    )
    let conversation = try RelayJSON.decoder.decode(
        SendMessageRequest.self,
        from: Data(
            (
                #"{"conversation_id":"chat-guid","text":"Here","media":[{"media_id":"upload_123"}],"#
                    + #""reply_to":{"message_id":"message-guid"}}"#
            ).utf8
        )
    )
    let participants = try RelayJSON.decoder.decode(
        SendMessageRequest.self,
        from: Data(
            #"{"participants":["Person@Example.COM","+1 500 555 0006"],"text":"Group hello"}"#.utf8
        )
    )

    #expect(direct.destination == .recipient(try RecipientHandle(type: .phone, value: "+1 500 555 0006")))
    #expect(conversation.destination == .conversation(try ConversationID(validating: "chat-guid")))
    #expect(conversation.content.media.map(\.mediaID.rawValue) == ["upload_123"])
    #expect(conversation.replyTo?.messageID.rawValue == "message-guid")
    #expect(participants.destination == .participants([
        try RecipientHandle(type: .email, value: "Person@Example.COM"),
        try RecipientHandle(type: .phone, value: "+1 500 555 0006"),
    ]))

    #expect(throws: (any Error).self) {
        try RelayJSON.decoder.decode(
            SendMessageRequest.self,
            from: Data(#"{"to":"a@example.com","conversation_id":"chat-guid","text":"ambiguous"}"#.utf8)
        )
    }
    #expect(throws: (any Error).self) {
        try RelayJSON.decoder.decode(
            SendMessageRequest.self,
            from: Data(#"{"to":"a@example.com","text":"hello","extra":true}"#.utf8)
        )
    }
    #expect(throws: RecipientHandle.ValidationError.self) {
        try RelayJSON.decoder.decode(
            SendMessageRequest.self,
            from: Data(#"{"to":"not-a-recipient","text":"hello"}"#.utf8)
        )
    }
    #expect(throws: SendMessageRequest.ValidationError.self) {
        try RelayJSON.decoder.decode(
            SendMessageRequest.self,
            from: Data(#"{"participants":["a@example.com"],"text":"too small"}"#.utf8)
        )
    }
    #expect(throws: SendMessageRequest.ValidationError.self) {
        try RelayJSON.decoder.decode(
            SendMessageRequest.self,
            from: Data(
                #"{"participants":["Person@example.com","person@EXAMPLE.com"],"text":"duplicate"}"#.utf8
            )
        )
    }
    #expect(throws: SendMessageRequest.ValidationError.self) {
        try RelayJSON.decoder.decode(
            SendMessageRequest.self,
            from: Data(
                #"{"to":"a@example.com","participants":["a@example.com","b@example.com"],"text":"ambiguous"}"#.utf8
            )
        )
    }
}

@Test
func sendReceiptRepresentsEveryProviderMessageAndMediaMapping() throws {
    let requestID = try RequestID(validating: "request-guid")
    let textMessageID = try MessageID(validating: "text-message-guid")
    let mediaMessageID = try MessageID(validating: "media-message-guid")
    let requestedMediaID = try MediaID(validating: "upload_fixture")
    let providerMediaID = try MediaID(validating: "provider-attachment-guid")
    let response = SendMessageResponse(
        requestID: requestID,
        status: .delivered,
        correlationStatus: .complete,
        conversationID: try ConversationID(validating: "group-chat-guid"),
        messages: [
            MessageReceipt(messageID: textMessageID, status: .delivered),
            MessageReceipt(messageID: mediaMessageID, status: .sent),
        ],
        media: [
            MediaReceipt(
                requestedMediaID: requestedMediaID,
                mediaID: providerMediaID,
                messageID: mediaMessageID
            )
        ],
        pollURL: "/v1/requests/request-guid"
    )

    let object = try jsonObject(response)
    #expect(object["message_id"] == nil)
    #expect(object["correlation_status"] as? String == "complete")
    #expect(object["conversation_id"] as? String == "group-chat-guid")
    let messages = try #require(object["messages"] as? [[String: Any]])
    #expect(messages.map { $0["message_id"] as? String } == [
        "text-message-guid",
        "media-message-guid",
    ])
    let media = try #require(object["media"] as? [[String: Any]])
    #expect(media.first?["requested_media_id"] as? String == "upload_fixture")
    #expect(media.first?["media_id"] as? String == "provider-attachment-guid")
    #expect(media.first?["message_id"] as? String == "media-message-guid")

    let pending = try jsonObject(MediaReceipt(
        requestedMediaID: requestedMediaID,
        mediaID: nil,
        messageID: nil
    ))
    #expect(pending["media_id"] is NSNull)
    #expect(pending["message_id"] is NSNull)
}

@Test
func errorAndPaginationContractsUseSnakeCase() throws {
    let requestID = try RequestID(validating: "request-123")
    let error = APIError(
        code: .invalidDestination,
        message: "Destination is invalid.",
        requestID: requestID,
        fieldDetails: [APIFieldError(field: "to.value", message: "Enter a phone number.")]
    )
    let page = PaginatedResponse(
        items: [try MessageID(validating: "message-1")],
        nextCursor: try Cursor(validating: "opaque"),
        hasMore: true
    )

    let errorObject = try jsonObject(error)
    #expect(errorObject["code"] as? String == "invalid_destination")
    #expect(errorObject["request_id"] as? String == "request-123")
    #expect((errorObject["field_details"] as? [[String: String]])?.first?["field"] == "to.value")

    let pageObject = try jsonObject(page)
    #expect(pageObject["items"] as? [String] == ["message-1"])
    #expect(pageObject["next_cursor"] as? String == "opaque")
    #expect(pageObject["has_more"] as? Bool == true)
}

@Test
func senderContractReportsConfigurationPermissionAndOperationSupport() throws {
    let sender = Sender(
        id: try SenderID(validating: "sender-account"),
        accountIdentity: "account-guid",
        login: nil,
        configured: true,
        availability: .permissionUnknown,
        reason: "Automation permission has not been tested.",
        permissions: SenderPermissions(
            automation: .unknown,
            accessibility: .notGranted
        ),
        capabilities: SenderCapabilities(
            text: .permissionUnknown,
            media: .unsupported,
            nativeReply: .unsupported
        )
    )

    let object = try jsonObject(sender)
    #expect(object["configured"] as? Bool == true)
    #expect(object["availability"] as? String == "permission_unknown")
    let permissions = try #require(object["permissions"] as? [String: String])
    #expect(permissions["automation"] == "unknown")
    #expect(permissions["accessibility"] == "not_granted")
    let capabilities = try #require(object["capabilities"] as? [String: String])
    #expect(capabilities["text"] == "permission_unknown")
    #expect(capabilities["media"] == "unsupported")
    #expect(capabilities["native_reply"] == "unsupported")
    #expect(capabilities["reactions"] == "unsupported")
    #expect(capabilities["group_creation"] == "unsupported")
}

@Test
func reactionWriteContractUsesOneMessageResourceWithoutPartCoordinates() throws {
    let request = SetReactionRequest(reaction: .love)
    let response = ReactionWriteResponse(
        requestID: try RequestID(validating: "reaction-request"),
        status: .applied,
        messageID: try MessageID(validating: "message-guid"),
        reaction: nil
    )

    let requestObject = try jsonObject(request)
    #expect(requestObject.count == 1)
    #expect(requestObject["reaction"] as? String == "love")
    let responseObject = try jsonObject(response)
    #expect(responseObject["message_id"] as? String == "message-guid")
    #expect(responseObject["status"] as? String == "applied")
    #expect(responseObject["reaction"] is NSNull)
    #expect(responseObject["part_index"] == nil)
}

@Test
func eventPayloadsUseStableNamesAndSnakeCaseJSON() throws {
    let observedAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
    let messageID = try MessageID(validating: "message-guid")
    let conversationID = try ConversationID(validating: "chat-guid")
    let reactionID = try MessageID(validating: "reaction-guid")
    let mediaID = try MediaID(validating: "attachment-guid")

    let created = RelayEvent.messageCreated(MessageCreatedEvent(
        messageID: messageID,
        conversationID: conversationID,
        isFromMe: false,
        observedAt: observedAt
    ))
    let updated = RelayEvent.messageUpdated(MessageUpdatedEvent(
        messageID: messageID,
        conversationID: conversationID,
        changedFields: [.deliveryState, .readState],
        observedAt: observedAt
    ))
    let reaction = RelayEvent.reactionAdded(ReactionChangedEvent(
        messageID: messageID,
        reactionID: reactionID,
        observedAt: observedAt
    ))
    let media = RelayEvent.mediaAvailable(MediaAvailableEvent(
        messageID: messageID,
        mediaID: mediaID,
        observedAt: observedAt
    ))

    #expect(created.type.rawValue == "message.created")
    #expect(updated.type.rawValue == "message.updated")
    #expect(reaction.type.rawValue == "reaction.added")
    #expect(media.type.rawValue == "media.available")

    let updatedObject = try jsonObject(updated.payload)
    #expect(updatedObject["message_id"] as? String == "message-guid")
    #expect(updatedObject["conversation_id"] as? String == "chat-guid")
    #expect(updatedObject["changed_fields"] as? [String] == ["delivery_state", "read_state"])
    #expect(updatedObject["observed_at"] as? String == "2023-11-14T22:13:20.000Z")

    let reactionObject = try jsonObject(reaction.payload)
    #expect(reactionObject["reaction_id"] as? String == "reaction-guid")
    let mediaObject = try jsonObject(media.payload)
    #expect(mediaObject["media_id"] as? String == "attachment-guid")
}

@Test
func streamControlEventsDeclareLiveOnlyRecovery() throws {
    let ready = RelayEvent.streamReady(StreamReadyEvent(
        databaseIdentity: "fixture-database",
        replaySupported: false
    ))
    let reset = RelayEvent.streamReset(StreamResetEvent(
        reason: .databaseChanged,
        message: "The Messages database changed. Reconnect and refetch REST resources."
    ))

    #expect(ready.type.rawValue == "stream.ready")
    #expect(reset.type.rawValue == "stream.reset")
    #expect(try jsonObject(ready.payload)["replay_supported"] as? Bool == false)
    #expect(try jsonObject(reset.payload)["refetch_required"] as? Bool == true)
}

private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try RelayJSON.encoder.encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
