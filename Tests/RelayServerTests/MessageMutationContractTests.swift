import Foundation
import Hummingbird
import HummingbirdTesting
import RelayCore
import Testing

@testable import RelayServer

@Test
func messageResponsesExposeCurrentMutationMetadata() async throws {
    let stamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
    let message = Message(
        id: try MessageID(validating: "unsent-message"), providerGUID: "unsent-message",
        conversationID: try ConversationID(validating: "chat-guid"), text: nil,
        sender: nil, isFromMe: true, createdAt: nil, deliveryState: .sent,
        readState: .unknown, deliveredAt: nil, readAt: nil, thread: nil,
        parts: [], reactions: [], attachments: [], editedAt: stamp, unsentAt: stamp
    )
    let harness = ServerTestHarness(store: APIStore(messages: [message]))
    let app = Application(router: harness.router())
    try await app.test(.router) { client in
        for uri in ["/v1/messages/unsent-message", "/v1/conversations/chat-guid/messages"] {
            let response = try await client.execute(uri: uri, method: .get, headers: authorizationHeaders())
            #expect(response.status == .ok)
            let value = try jsonObject(response.body)
            let object = uri.hasPrefix("/v1/messages/") ? value
                : try #require((value["items"] as? [[String: Any]])?.first)
            #expect(object["edited_at"] is String)
            #expect(object["unsent_at"] is String)
            #expect(object["text"] is NSNull)
            #expect((object["parts"] as? [Any])?.isEmpty == true)
            #expect((object["attachments"] as? [Any])?.isEmpty == true)
        }
    }
}
