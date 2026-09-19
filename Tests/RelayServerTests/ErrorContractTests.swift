import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import RelayCore
import Testing

@testable import relay_server

@Test
func authenticationAndMalformedJSONUseTheStableErrorShape() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let unauthenticated = try await client.execute(uri: "/v1/status", method: .get)
        try expectError(unauthenticated, status: .unauthorized, code: .invalidAuthentication)

        let malformed = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: #"{"to": "#)
        )
        try expectError(malformed, status: .badRequest, code: .malformedJSON)
        #expect(harness.sender.requests.isEmpty)
    }
}

@Test
func destinationErrorsDistinguishMissingAmbiguousInvalidAndDisallowed() async throws {
    let harness = ServerTestHarness(allowedRecipients: ["allowed@example.com"])
    let app = Application(router: harness.router())
    let cases: [(String, HTTPResponse.Status, APIErrorCode)] = [
        (#"{"text":"hello"}"#, .unprocessableContent, .invalidDestination),
        (#"{"conversation_id":"chat-guid","to":"a@example.com","text":"hello"}"#, .badRequest, .ambiguousDestination),
        (#"{"to":"not-a-phone","text":"hello"}"#, .unprocessableContent, .invalidDestination),
        (#"{"to":"friend@example.com","text":"hello"}"#, .forbidden, .disallowedRecipient),
        (#"{"participants":["a@example.com"],"text":"hello"}"#, .unprocessableContent, .invalidDestination),
        (
            #"{"participants":["A@example.com","a@EXAMPLE.com"],"text":"hello"}"#,
            .unprocessableContent,
            .invalidDestination
        ),
        (
            #"{"to":"a@example.com","participants":["a@example.com","b@example.com"],"text":"hello"}"#,
            .badRequest,
            .ambiguousDestination
        ),
        (
            #"{"participants":["allowed@example.com","blocked@example.com"],"text":"hello"}"#,
            .forbidden,
            .disallowedRecipient
        ),
    ]

    try await app.test(.router) { client in
        for (body, status, code) in cases {
            let response = try await client.execute(
                uri: "/v1/messages",
                method: .post,
                headers: authorizationHeaders([.contentType: "application/json"]),
                body: ByteBuffer(string: body)
            )
            try expectError(response, status: status, code: code)
        }
    }
    #expect(harness.sender.requests.isEmpty)

    let participants = [
        try RecipientHandle.direct(value: "allowed@example.com"),
        try RecipientHandle.direct(value: "+15005550006"),
    ]
    let contexts = try ["group-one", "group-two"].map { value in
        let id = try ConversationID(validating: value)
        return ConversationSendContext(
            conversationID: id,
            providerGUID: value,
            accountID: "account-guid",
            accountLogin: "sender@example.com",
            recipients: participants
        )
    }
    let ambiguousHarness = ServerTestHarness(
        store: APIStore(matchingContexts: contexts),
        allowedRecipients: participants.map(\.value)
    )
    let ambiguousApp = Application(router: ambiguousHarness.router())
    try await ambiguousApp.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: """
                {"participants":["allowed@example.com","+1 500 555 0006"],"text":"hello"}
                """)
        )
        try expectError(response, status: .conflict, code: .ambiguousConversation)
    }
    #expect(ambiguousHarness.sender.requests.isEmpty)

    let blockedHarness = ServerTestHarness(
        store: APIStore(matchingContexts: contexts),
        allowedRecipients: ["allowed@example.com"]
    )
    let blockedApp = Application(router: blockedHarness.router())
    try await blockedApp.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: """
                {"participants":["allowed@example.com","+15005550006"],"text":"hello"}
                """)
        )
        try expectError(response, status: .forbidden, code: .disallowedRecipient)
    }
}

@Test
func unknownResourcesAndUnsupportedCapabilitiesHaveDistinctCodes() async throws {
    let sender = FakeMessageSender.available(capabilities: .init(
        text: .available,
        media: .unsupported,
        nativeReply: .unsupported
    ))
    let harness = ServerTestHarness(sender: sender)
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let unknownConversation = try await client.execute(
            uri: "/v1/conversations/missing",
            method: .get,
            headers: authorizationHeaders()
        )
        try expectError(unknownConversation, status: .notFound, code: .unknownConversation)

        let unknownConversationRead = try await client.execute(
            uri: "/v1/conversations/missing/read",
            method: .put,
            headers: authorizationHeaders()
        )
        try expectError(unknownConversationRead, status: .notFound, code: .unknownConversation)

        let unknownMessage = try await client.execute(
            uri: "/v1/messages/missing",
            method: .get,
            headers: authorizationHeaders()
        )
        try expectError(unknownMessage, status: .notFound, code: .unknownMessage)

        let unknownMedia = try await client.execute(
            uri: "/v1/media/missing",
            method: .get,
            headers: authorizationHeaders()
        )
        try expectError(unknownMedia, status: .notFound, code: .unknownMedia)

        let unsupportedReply = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: #"{"conversation_id":"chat-guid","text":"reply","reply_to":{"message_id":"message-root"}}"#)
        )
        try expectError(unsupportedReply, status: .notImplemented, code: .unsupportedCapability)

        let unsupportedGroup = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: """
                {"participants":["friend@example.com","+1 500 555 0006"],"text":"group"}
                """)
        )
        try expectError(unsupportedGroup, status: .notImplemented, code: .unsupportedCapability)
    }
    #expect(sender.requests.isEmpty)
}

@Test
func senderDatabaseCursorAndDuplicateFailuresUseHonestStatuses() async throws {
    let unavailableStatus = Sender(
        id: try SenderID(validating: "fake-sender"),
        accountIdentity: nil,
        login: nil,
        configured: false,
        availability: .unavailable,
        reason: "Synthetic unavailable sender.",
        capabilities: .init(text: .unavailable, media: .unsupported, nativeReply: .unsupported)
    )
    let unavailableSender = FakeMessageSender(
        sender: unavailableStatus,
        outcome: .error(.unavailable("Synthetic unavailable sender."))
    )
    let unavailableHarness = ServerTestHarness(sender: unavailableSender)
    let unavailableApp = Application(router: unavailableHarness.router())
    try await unavailableApp.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: authorizationHeaders([.contentType: "application/json"]),
            body: ByteBuffer(string: #"{"to":"+15005550006","text":"hello"}"#)
        )
        try expectError(response, status: .serviceUnavailable, code: .senderUnavailable)
    }

    let databaseHarness = ServerTestHarness(store: APIStore(readError: .cannotOpen("synthetic")))
    let databaseApp = Application(router: databaseHarness.router())
    try await databaseApp.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/conversations",
            method: .get,
            headers: authorizationHeaders()
        )
        try expectError(response, status: .serviceUnavailable, code: .databaseUnavailable)
    }

    let duplicateHarness = ServerTestHarness()
    let duplicateApp = Application(router: duplicateHarness.router())
    try await duplicateApp.test(.router) { client in
        let headers = authorizationHeaders([
            .contentType: "application/json",
            .init("idempotency-key")!: "same-operation",
        ])
        let body = ByteBuffer(string: #"{"to":"+15005550006","text":"hello"}"#)
        let first = try await client.execute(uri: "/v1/messages", method: .post, headers: headers, body: body)
        #expect(first.status == .accepted)
        let second = try await client.execute(uri: "/v1/messages", method: .post, headers: headers, body: body)
        #expect(second.status == .accepted)
        #expect(Data(second.body.readableBytesView) == Data(first.body.readableBytesView))

        let changed = try await client.execute(
            uri: "/v1/messages",
            method: .post,
            headers: headers,
            body: ByteBuffer(string: #"{"to":"+15005550006","text":"changed"}"#)
        )
        try expectError(changed, status: .conflict, code: .duplicateRequest)

        let cursor = try await client.execute(
            uri: "/v1/conversations?cursor=opaque-but-wrong",
            method: .get,
            headers: authorizationHeaders()
        )
        try expectError(cursor, status: .badRequest, code: .invalidCursor)
    }
}

@Test
func typingDraftConflictsUseAStableConflictError() async throws {
    let harness = ServerTestHarness(
        typingError: .draftConflict("The conversation contains an existing draft.")
    )
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/conversations/chat-guid/typing",
            method: .put,
            headers: authorizationHeaders()
        )
        try expectError(response, status: .conflict, code: .typingConflict)
    }

    let missingHarness = ServerTestHarness()
    let missingApp = Application(router: missingHarness.router())
    try await missingApp.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/conversations/missing/typing",
            method: .put,
            headers: authorizationHeaders()
        )
        try expectError(response, status: .notFound, code: .unknownConversation)
    }
}

@Test
func mediaSafetyErrorsCoverUnsafeAndOversizedUploads() async throws {
    let harness = ServerTestHarness(maximumMediaBytes: 4)
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let unsafe = try await client.execute(
            uri: "/v1/media",
            method: .post,
            headers: authorizationHeaders([
                .contentType: "image/jpeg",
                .init("x-filename")!: "../photo.jpg",
            ]),
            body: ByteBuffer(bytes: [1])
        )
        try expectError(unsafe, status: .unprocessableContent, code: .unsafeMedia)

        let tooLarge = try await client.execute(
            uri: "/v1/media",
            method: .post,
            headers: authorizationHeaders([
                .contentType: "image/jpeg",
                .init("x-filename")!: "photo.jpg",
            ]),
            body: ByteBuffer(bytes: [1, 2, 3, 4, 5])
        )
        try expectError(tooLarge, status: .contentTooLarge, code: .mediaTooLarge)
    }
}

private func expectError(
    _ response: TestResponse,
    status: HTTPResponse.Status,
    code: APIErrorCode
) throws {
    #expect(response.status == status)
    let error = try errorBody(response.body)
    #expect(error.code == code)
    #expect(!error.message.isEmpty)
    #expect(!error.requestID.rawValue.isEmpty)
    #expect(response.headers[.init("x-request-id")!] == error.requestID.rawValue)
}
