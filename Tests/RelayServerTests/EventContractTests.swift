import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import RelayCore
import Testing

@testable import RelayServer

@Test
func eventsRouteStreamsAuthenticatedSSEFrames() async throws {
    let created = RelayEvent.messageCreated(MessageCreatedEvent(
        messageID: try MessageID(validating: "message-guid"),
        conversationID: try ConversationID(validating: "chat-guid"),
        isFromMe: false,
        observedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
    ))
    let observer = TestMessageChangeObserver(events: [
        .streamReady(StreamReadyEvent(databaseIdentity: "fixture-database")),
        created,
    ])
    let harness = ServerTestHarness(eventObserver: observer)
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/events",
            method: .get,
            headers: authorizationHeaders([.accept: "text/event-stream"])
        )
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "text/event-stream; charset=utf-8")
        #expect(response.headers[.init("cache-control")!] == "no-cache")
        let body = String(buffer: response.body)
        #expect(body.hasPrefix("retry: 3000\n\n"))
        #expect(body.contains("event: stream.ready\n"))
        #expect(body.contains(#"data: {"database_identity":"fixture-database","replay_supported":true}"#))
        #expect(body.contains("\nid: "))
        #expect(body.contains("event: message.created\n"))
        #expect(body.contains(#""message_id":"message-guid""#))
    }
}

@Test
func eventsRouteRequiresAuthenticationAndResetsUnavailableReplayRequests() async throws {
    let harness = ServerTestHarness()
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let unauthorized = try await client.execute(uri: "/v1/events", method: .get)
        #expect(unauthorized.status == .unauthorized)
        #expect(unauthorized.headers[.contentType] == "application/json; charset=utf-8")

        let replay = try await client.execute(
            uri: "/v1/events",
            method: .get,
            headers: authorizationHeaders([.init("last-event-id")!: "event-123"])
        )
        #expect(replay.status == .ok)
        #expect(replay.headers[.contentType] == "text/event-stream; charset=utf-8")
        let body = String(buffer: replay.body)
        #expect(body.contains("event: stream.reset\n"))
        #expect(body.contains(#""reason":"replay_unavailable""#))
    }
}

@Test
func eventsRouteReturnsJSONWhenDatabaseIsUnavailableBeforeStreaming() async throws {
    let store = APIStore(database: DatabaseStatus(
        ready: false,
        identity: nil,
        error: "Synthetic database failure."
    ))
    let harness = ServerTestHarness(store: store)
    let app = Application(router: harness.router())

    try await app.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/events",
            method: .get,
            headers: authorizationHeaders([.accept: "text/event-stream"])
        )
        #expect(response.status == .serviceUnavailable)
        #expect(response.headers[.contentType] == "application/json; charset=utf-8")
        let error = try RelayJSON.decoder.decode(
            APIError.self,
            from: Data(response.body.readableBytesView)
        )
        #expect(error.code == .databaseUnavailable)
    }
}

@Test
func eventsRouteWritesKeepAliveCommentsWhileTheSourceIsIdle() async throws {
    let observer = DelayedFinishMessageChangeObserver(delay: .milliseconds(25))
    let events = EventService(observer: observer)
    let router = Router(context: RelayRequestContext.self)
    EventRoutes(
        database: APIStore(),
        events: events,
        heartbeatInterval: .milliseconds(5)
    ).register(on: router)
    let app = Application(router: router)

    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/v1/events", method: .get)
        #expect(response.status == .ok)
        #expect(String(buffer: response.body).contains(": keep-alive\n\n"))
    }
    await events.shutdown()
}

private final class DelayedFinishMessageChangeObserver: MessageChangeObserving, Sendable {
    let delay: Duration

    init(delay: Duration) {
        self.delay = delay
    }

    func events() -> AsyncThrowingStream<RelayEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.streamReady(StreamReadyEvent(databaseIdentity: "fixture-database")))
            let task = Task {
                do {
                    try await ContinuousClock().sleep(for: delay)
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func shutdown() async throws {}
}
