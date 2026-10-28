import Foundation
import Testing

@testable import RelayCore

@Test
func eventServiceSharesOneObserverAndGivesEachSubscriberStreamReady() async throws {
    let observer = ControlledMessageChangeObserver()
    let service = EventService(observer: observer)
    var first = await service.events().makeAsyncIterator()

    let firstReady = try #require(await first.next())
    #expect(firstReady.event.type == .streamReady)

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

    let firstMessage = await first.next()
    let secondMessage = await second.next()
    #expect(firstMessage?.event == message)
    #expect(secondMessage?.event == message)
    #expect(firstMessage?.eventID != nil)
    #expect(secondMessage?.eventID == firstMessage?.eventID)
    await service.shutdown()
}

@Test(arguments: [false, true])
func eventServiceResetsAndClosesAClientWhoseBufferOverflows(mutation: Bool) async throws {
    let observer = ControlledMessageChangeObserver()
    let service = EventService(observer: observer, subscriberBufferSize: 1)
    var iterator = await service.events().makeAsyncIterator()
    _ = await iterator.next()

    for suffix in 1...3 {
        observer.yield(try replayTestEvent(suffix: suffix, mutation: mutation))
    }
    try await ContinuousClock().sleep(for: .milliseconds(20))

    var resumeCursor: EventCursor?
    while let delivery = await iterator.next() {
        if case .streamReset(let payload) = delivery.event,
           payload.reason == .subscriberOverflow,
           payload.refetchRequired == false {
            resumeCursor = payload.resumeAfterEventID
        }
    }
    let cursor = try #require(resumeCursor)
    var resumed = await service.events(after: cursor).makeAsyncIterator()
    #expect(await resumed.next()?.event.type == .streamReady)
    let replayed = try #require(await resumed.next())
    #expect(replayed.event == (try replayTestEvent(suffix: 3, mutation: mutation)))
    await service.shutdown()
}

@Test(arguments: [false, true])
func eventServiceReplaysEventsAfterAValidCursor(mutation: Bool) async throws {
    let observer = ControlledMessageChangeObserver()
    let service = EventService(observer: observer)
    var live = await service.events().makeAsyncIterator()
    _ = await live.next()

    for suffix in 1...3 {
        observer.yield(try replayTestEvent(suffix: suffix, mutation: mutation))
    }
    let first = try #require(await live.next())
    _ = await live.next()
    _ = await live.next()
    let cursor = try #require(first.eventID)

    var replay = await service.events(after: cursor).makeAsyncIterator()
    #expect(await replay.next()?.event.type == .streamReady)
    let second = try #require(await replay.next())
    let third = try #require(await replay.next())
    #expect(second.eventID != first.eventID)
    #expect(third.eventID != second.eventID)
    #expect(second.event == (try replayTestEvent(suffix: 2, mutation: mutation)))
    #expect(third.event == (try replayTestEvent(suffix: 3, mutation: mutation)))
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

    #expect(await iterator.next()?.event == reset)
    #expect(await iterator.next() == nil)
    await service.shutdown()
}

private func replayTestEvent(suffix: Int, mutation: Bool) throws -> RelayEvent {
    let id = try MessageID(validating: "message-\(suffix)")
    let conversation = try ConversationID(validating: "chat-guid")
    let time = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
    if mutation {
        return .messageUpdated(MessageUpdatedEvent(
            messageID: id, conversationID: conversation,
            changedFields: [.unsentAt, .text, .parts, .attachments], observedAt: time
        ))
    }
    return .messageCreated(MessageCreatedEvent(
        messageID: id, conversationID: conversation, isFromMe: false, observedAt: time
    ))
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
