import Foundation
import Hummingbird
import HummingbirdTesting
import RelayCore
import Testing

@testable import RelayServer

@Test
func scheduledRouteReturnsMessageConversationAndScheduleWithoutSending() async throws {
    let time = Timestamp(Date(timeIntervalSince1970: 2_000_000_000))
    let message = Message(
        id: try MessageID(validating: "scheduled-fixture"), providerGUID: "scheduled-fixture",
        conversationID: try ConversationID(validating: "chat-guid"), text: "Scheduled fixture",
        sender: nil, isFromMe: true, createdAt: time, deliveryState: .notSent,
        readState: .unknown, deliveredAt: nil, readAt: nil, thread: nil,
        reactions: [], attachments: [], schedule: MessageSchedule(scheduledAt: time, type: 2, state: 1)
    )
    let harness = ServerTestHarness(store: APIStore(messages: [message]))
    try await Application(router: harness.router()).test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/messages/scheduled?limit=7&include_attachments=true", method: .get, headers: authorizationHeaders()
        )
        #expect(response.status == .ok)
        let page = try RelayJSON.decoder.decode(PaginatedResponse<Message>.self, from: Data(response.body.readableBytesView))
        #expect(page.items == [message])
        #expect(harness.store.lastScheduledOptions == ScheduledMessageListOptions(limit: 7, includeAttachments: true))
        #expect(harness.store.lastMessageListOptions == nil)
        #expect(harness.sender.requests.isEmpty)
    }
}

@Test
func scheduledRouteValidatesOptionsAndPreservesAuthenticationAndDatabaseErrors() async throws {
    let harness = ServerTestHarness()
    try await Application(router: harness.router()).test(.router) { client in
        let denied = try await client.execute(uri: "/v1/messages/scheduled", method: .get)
        #expect(denied.status == .unauthorized)
        for query in ["limit=0", "limit=201", "include_attachments=no", "cursor=invalid"] {
            let response = try await client.execute(
                uri: "/v1/messages/scheduled?\(query)", method: .get, headers: authorizationHeaders()
            )
            #expect(response.status == .badRequest)
            #expect(try errorBody(response.body).code == (query.hasPrefix("cursor=") ? .invalidCursor : .invalidRequest))
        }
        #expect(harness.sender.requests.isEmpty)
    }
    let unavailable = ServerTestHarness(store: APIStore(readError: .cannotOpen("Synthetic unavailable database.")))
    try await Application(router: unavailable.router()).test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/messages/scheduled", method: .get, headers: authorizationHeaders()
        )
        #expect(response.status == .serviceUnavailable)
    }
}
