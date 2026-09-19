import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import relay_server

@Test
func paginationQueryValidationRejectsInvalidLimitsBooleansAndModes() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())
    let cases = [
        "/v1/conversations?limit=0",
        "/v1/conversations?limit=201",
        "/v1/conversations?unread_only=perhaps",
        "/v1/conversations?participant=not-a-recipient",
        "/v1/conversations/chat-guid/messages?include_attachments=yes",
        "/v1/conversations/chat-guid/messages?search_mode=prefix",
    ]

    try await app.test(.router) { client in
        for uri in cases {
            let response = try await client.execute(
                uri: uri,
                method: .get,
                headers: authorizationHeaders()
            )
            if uri.contains("participant=") {
                #expect(response.status == .unprocessableContent)
                #expect(try errorBody(response.body).code == .invalidDestination)
            } else {
                #expect(response.status == .badRequest)
                #expect(try errorBody(response.body).code == .invalidRequest)
            }
        }
    }
}

@Test
func messageSearchDecodesSpacesAndPreservesEncodedPlusSigns() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        _ = try await client.execute(
            uri: "/v1/conversations/chat-guid/messages?q=Relay+thread&search_mode=exact",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(harness.store.lastMessageListOptions?.search == "Relay thread")

        _ = try await client.execute(
            uri: "/v1/conversations/chat-guid/messages?q=friend%2Brelay%40example.com",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(harness.store.lastMessageListOptions?.search == "friend+relay@example.com")

        _ = try await client.execute(
            uri: "/v1/conversations/chat-guid/messages?q=literal%ZZvalue",
            method: .get,
            headers: authorizationHeaders()
        )
        #expect(harness.store.lastMessageListOptions?.search == "literal%ZZvalue")
    }
}
