import Foundation
import Testing

@testable import RelayCore

@Test
func eventServiceSharesOneObserverAndGivesEachSubscriberStreamReady() async throws {
    let observer = ControlledMessageChangeObserver()
    let service = EventService(observer: observer)
    var first = await service.events().makeAsyncIterator()

    let firstReady = try #require(await first.next())
    #expect(firstReady.type == .streamReady)

    var second = await service.events().makeAsyncIterator()
    let secondReady = try #require(await second.next())
    #expect(secondReady == firstReady)
    #expect(observer.startCount == 1)

    let message = RelayEvent.messageCreated(MessageCreatedEvent(
        messageID: try MessageID(validating: "message-guid"),
        conversationID: try ConversationID(validating: "chat-guid"),
        isFromMe: false,
        observedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
    ))
    observer.yield(message)

    #expect(await first.next() == message)
    #expect(await second.next() == message)
    await service.shutdown()
}

@Test
func eventServiceResetsAndClosesAClientWhoseBufferOverflows() async throws {
    let observer = ControlledMessageChangeObserver()
    let service = EventService(observer: observer, subscriberBufferSize: 1)
    var iterator = await service.events().makeAsyncIterator()
    _ = await iterator.next()

    for suffix in 1...3 {
        observer.yield(.messageCreated(MessageCreatedEvent(
            messageID: try MessageID(validating: "message-\(suffix)"),
            conversationID: try ConversationID(validating: "chat-guid"),
            isFromMe: false,
            observedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )))
    }
    try await ContinuousClock().sleep(for: .milliseconds(20))

    var receivedReset = false
    while let event = await iterator.next() {
        if case .streamReset(let payload) = event {
            receivedReset = payload.reason == .subscriberOverflow
        }
    }
    #expect(receivedReset)
    await service.shutdown()
}

@Test
func eventServiceClosesSubscribersAfterAReset() async {
    let observer = ControlledMessageChangeObserver()
    let service = EventService(observer: observer)
    var iterator = await service.events().makeAsyncIterator()
    _ = await iterator.next()

    let reset = RelayEvent.streamReset(StreamResetEvent(
        reason: .databaseChanged,
        message: "Reconnect and refetch."
    ))
    observer.yield(reset)

    #expect(await iterator.next() == reset)
    #expect(await iterator.next() == nil)
    await service.shutdown()
}

private final class ControlledMessageChangeObserver: MessageChangeObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation?
    private var starts = 0

    var startCount: Int { lock.withLock { starts } }

    func events() -> AsyncThrowingStream<RelayEvent, any Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                starts += 1
                self.continuation = continuation
            }
            continuation.yield(.streamReady(StreamReadyEvent(databaseIdentity: "fixture-database")))
        }
    }

    func yield(_ event: RelayEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    func shutdown() async throws {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }
}
