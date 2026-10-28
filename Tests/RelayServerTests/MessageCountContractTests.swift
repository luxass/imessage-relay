import Foundation
import Hummingbird
import HummingbirdTesting
import RelayCore
import Testing

@testable import RelayServer

@Test
func countRouteUsesExplicitTimeZonesAndReturnsTheTypedRange() async throws {
    let harness = ServerTestHarness()
    try await Application(router: harness.router()).test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/conversations/chat-guid/message-counts?from=2026-01-01T02:00:00%2B02:00&to=2026-01-02T02:00:00%2B02:00",
            method: .get, headers: authorizationHeaders()
        )
        #expect(response.status == .ok)
        let counts = try RelayJSON.decoder.decode(MessageCounts.self, from: Data(response.body.readableBytesView))
        #expect(counts.conversationID.rawValue == "chat-guid")
        #expect(counts.sent == 12 && counts.received == 34)
        #expect(counts.from.date == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(counts.to.date == Date(timeIntervalSince1970: 1_767_312_000))
        #expect(harness.store.lastCountRange?.from == counts.from)
        #expect(harness.store.lastCountRange?.to == counts.to)
        #expect(harness.sender.requests.isEmpty)
    }
}

@Test
func countRouteRejectsInvalidRangesAndPreservesAuthenticationAndStorageErrors() async throws {
    let harness = ServerTestHarness()
    let path = "/v1/conversations/chat-guid/message-counts"
    let valid = "from=2026-01-01T00:00:00Z&to=2026-01-02T00:00:00Z"
    try await Application(router: harness.router()).test(.router) { client in
        let denied = try await client.execute(uri: "\(path)?\(valid)", method: .get)
        #expect(denied.status == .unauthorized)
        for query in ["", "from=2026-01-01T00:00:00Z", "to=2026-01-02T00:00:00Z",
                      "from=2026-01-01&to=2026-01-02T00:00:00Z",
                      "from=2026-01-01T00:00:00&to=2026-01-02T00:00:00Z",
                      "from=invalidZ&to=2026-01-02T00:00:00Z",
                      "from=2026-01-02T00:00:00Z&to=2026-01-02T00:00:00Z",
                      "from=2026-01-03T00:00:00Z&to=2026-01-02T00:00:00Z"] {
            let response = try await client.execute(uri: "\(path)?\(query)", method: .get, headers: authorizationHeaders())
            #expect(response.status == .badRequest)
            #expect(try errorBody(response.body).code == .invalidRequest)
        }
        let missing = try await client.execute(
            uri: "/v1/conversations/missing/message-counts?\(valid)", method: .get, headers: authorizationHeaders()
        )
        #expect(missing.status == .notFound)
        #expect(harness.sender.requests.isEmpty)
    }
    let unavailable = ServerTestHarness(store: APIStore(readError: .cannotOpen("Synthetic unavailable database.")))
    try await Application(router: unavailable.router()).test(.router) { client in
        let response = try await client.execute(uri: "\(path)?\(valid)", method: .get, headers: authorizationHeaders())
        #expect(response.status == .serviceUnavailable)
    }
}
