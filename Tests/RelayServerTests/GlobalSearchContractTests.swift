import Foundation
import Hummingbird
import HummingbirdTesting
import RelayCore
import Testing

@testable import RelayServer

@Test
func globalSearchRouteForwardsValidatedOptionsAndReturnsConversationContext() async throws {
    let harness = ServerTestHarness()
    try await Application(router: harness.router()).test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/messages?q=CAF%C3%89+invoice&search_mode=exact&limit=7&include_attachments=true",
            method: .get, headers: authorizationHeaders()
        )
        #expect(response.status == .ok)
        let page = try RelayJSON.decoder.decode(
            PaginatedResponse<Message>.self, from: Data(response.body.readableBytesView)
        )
        #expect(!page.items.isEmpty)
        #expect(page.items.allSatisfy { $0.conversationID.rawValue == "chat-guid" })
        #expect(harness.store.lastMessageListOptions == MessageListOptions(
            limit: 7, includeAttachments: true, search: "CAFÉ invoice", searchMode: .exact
        ))
        #expect(harness.sender.requests.isEmpty)
    }
}

@Test
func globalSearchPreservesDatabaseFailureResponses() async throws {
    let harness = ServerTestHarness(store: APIStore(readError: .cannotOpen("Synthetic unavailable database.")))
    try await Application(router: harness.router()).test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/messages?q=hello", method: .get, headers: authorizationHeaders()
        )
        #expect(response.status == .serviceUnavailable)
        #expect(try errorBody(response.body).code == .databaseUnavailable)
    }
}

@Test
func globalSearchRejectsMissingTextAndInvalidOptionsAndRequiresAuthentication() async throws {
    let harness = ServerTestHarness()
    try await Application(router: harness.router()).test(.router) { client in
        let denied = try await client.execute(uri: "/v1/messages?q=hello", method: .get)
        #expect(denied.status == .unauthorized)
        for query in ["", "?q=", "?q=++", "?q=x&search_mode=invalid", "?q=x&limit=0", "?q=x&limit=201",
                      "?q=x&include_attachments=no"] {
            let response = try await client.execute(
                uri: "/v1/messages\(query)", method: .get, headers: authorizationHeaders()
            )
            #expect(response.status == .badRequest)
            #expect(try errorBody(response.body).code == .invalidRequest)
        }
        let cursor = try await client.execute(
            uri: "/v1/messages?q=hello&cursor=invalid", method: .get, headers: authorizationHeaders()
        )
        #expect(cursor.status == .badRequest)
        #expect(try errorBody(cursor.body).code == .invalidCursor)
        #expect(harness.sender.requests.isEmpty)
    }
}
