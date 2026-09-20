import Foundation

public actor EventService {
    private struct CursorComponents {
        let runID: UUID
        let sequence: UInt64
    }

    private let observer: any MessageChangeObserving
    private let subscriberBufferSize: Int
    private let historyCapacity: Int
    private var subscribers: [UUID: AsyncStream<RelayEventDelivery>.Continuation] = [:]
    private var observerTask: Task<Void, Never>?
    private var observerRunID: UUID?
    private var readyDelivery: RelayEventDelivery?
    private var eventRunID: UUID?
    private var nextSequence: UInt64 = 1
    private var history: [RelayEventDelivery] = []

    public init(
        observer: any MessageChangeObserving,
        subscriberBufferSize: Int = 256,
        historyCapacity: Int = 256
    ) {
        self.observer = observer
        self.subscriberBufferSize = max(1, subscriberBufferSize)
        self.historyCapacity = max(1, min(historyCapacity, subscriberBufferSize))
    }

    public func events(after cursor: EventCursor? = nil) -> AsyncStream<RelayEventDelivery> {
        let subscriberID = UUID()
        let pair = AsyncStream.makeStream(
            of: RelayEventDelivery.self,
            bufferingPolicy: .bufferingNewest(subscriberBufferSize + 1)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID) }
        }

        if let cursor {
            guard let readyDelivery, let replay = replay(after: cursor) else {
                if let readyDelivery { pair.continuation.yield(readyDelivery) }
                pair.continuation.yield(RelayEventDelivery(
                    eventID: nil,
                    event: .streamReset(StreamResetEvent(
                        reason: .replayUnavailable,
                        message: "The event cursor is no longer available. Reconnect without it and refetch REST resources."
                    ))
                ))
                pair.continuation.finish()
                return pair.stream
            }
            subscribers[subscriberID] = pair.continuation
            pair.continuation.yield(readyDelivery)
            for delivery in replay {
                guard yield(delivery, to: subscriberID) else { break }
            }
            return pair.stream
        }

        subscribers[subscriberID] = pair.continuation
        if let readyDelivery { pair.continuation.yield(readyDelivery) }
        if observerTask == nil { startObserver() }
        return pair.stream
    }

    public func shutdown() async {
        let task = observerTask
        observerRunID = nil
        observerTask = nil
        clearRun()
        task?.cancel()
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
        try? await observer.shutdown()
        await task?.value
    }

    private func startObserver() {
        let runID = UUID()
        observerRunID = runID
        let observer = observer
        observerTask = Task { [weak self] in
            do {
                for try await event in observer.events() {
                    guard let self else { return }
                    await self.publish(event, observerRunID: runID)
                }
                await self?.observerFinished(observerRunID: runID)
            } catch is CancellationError {
                await self?.observerFinished(observerRunID: runID)
            } catch {
                await self?.observerFailed(error, observerRunID: runID)
            }
        }
    }

    private func publish(_ event: RelayEvent, observerRunID runID: UUID) {
        guard observerRunID == runID else { return }
        if case .streamReady(let payload) = event {
            beginRun(databaseIdentity: payload.databaseIdentity)
            return
        }
        if case .streamReset = event {
            publishTerminal(event, observerRunID: runID)
            return
        }

        let delivery = sequenced(event)
        history.append(delivery)
        if history.count > historyCapacity {
            history.removeFirst(history.count - historyCapacity)
        }
        for subscriberID in Array(subscribers.keys) {
            _ = yield(delivery, to: subscriberID)
        }
    }

    private func beginRun(databaseIdentity: String) {
        eventRunID = UUID()
        nextSequence = 1
        history.removeAll(keepingCapacity: true)
        let delivery = RelayEventDelivery(
            eventID: nil,
            event: .streamReady(StreamReadyEvent(
                databaseIdentity: databaseIdentity,
                replaySupported: true
            ))
        )
        readyDelivery = delivery
        for continuation in subscribers.values {
            continuation.yield(delivery)
        }
    }

    private func sequenced(_ event: RelayEvent) -> RelayEventDelivery {
        guard let eventRunID else {
            preconditionFailure("A stream.ready event must start the event run.")
        }
        let cursor = makeCursor(runID: eventRunID, sequence: nextSequence)
        nextSequence += 1
        return RelayEventDelivery(eventID: cursor, event: event)
    }

    @discardableResult
    private func yield(_ delivery: RelayEventDelivery, to subscriberID: UUID) -> Bool {
        guard let continuation = subscribers[subscriberID] else { return false }
        switch continuation.yield(delivery) {
        case .enqueued:
            return true
        case .dropped:
            subscribers[subscriberID] = nil
            continuation.yield(RelayEventDelivery(
                eventID: nil,
                event: .streamReset(StreamResetEvent(
                    reason: .subscriberOverflow,
                    message: "The event client fell behind. Reconnect with the supplied event cursor.",
                    refetchRequired: false,
                    resumeAfterEventID: cursorBeforeRetainedHistory()
                ))
            ))
            continuation.finish()
            return false
        case .terminated:
            subscribers[subscriberID] = nil
            return false
        @unknown default:
            subscribers[subscriberID] = nil
            return false
        }
    }

    private func replay(after cursor: EventCursor) -> [RelayEventDelivery]? {
        guard let components = parse(cursor), components.runID == eventRunID else { return nil }
        let latestSequence = nextSequence - 1
        guard components.sequence <= latestSequence else { return nil }
        guard let firstCursor = history.first?.eventID,
              let first = parse(firstCursor) else {
            return components.sequence == 0 ? [] : nil
        }
        guard components.sequence >= first.sequence - 1 else { return nil }
        return history.filter { delivery in
            guard let eventID = delivery.eventID, let value = parse(eventID) else { return false }
            return value.sequence > components.sequence
        }
    }

    private func cursorBeforeRetainedHistory() -> EventCursor? {
        guard let eventRunID else { return nil }
        let firstSequence = history.first?.eventID.flatMap(parse)?.sequence ?? nextSequence
        return makeCursor(runID: eventRunID, sequence: firstSequence - 1)
    }

    private func makeCursor(runID: UUID, sequence: UInt64) -> EventCursor {
        EventCursor(rawValue: "\(runID.uuidString.lowercased()):\(sequence)")
    }

    private func parse(_ cursor: EventCursor) -> CursorComponents? {
        guard let separator = cursor.rawValue.lastIndex(of: ":"),
              let runID = UUID(uuidString: String(cursor.rawValue[..<separator])),
              let sequence = UInt64(cursor.rawValue[cursor.rawValue.index(after: separator)...]) else {
            return nil
        }
        return CursorComponents(runID: runID, sequence: sequence)
    }

    private func publishTerminal(_ event: RelayEvent, observerRunID runID: UUID) {
        let delivery = RelayEventDelivery(eventID: nil, event: event)
        for continuation in subscribers.values {
            continuation.yield(delivery)
            continuation.finish()
        }
        subscribers.removeAll()
        finishCurrentRun(observerRunID: runID)
    }

    private func observerFailed(_: any Error, observerRunID runID: UUID) {
        guard observerRunID == runID else { return }
        publishTerminal(.streamReset(StreamResetEvent(
            reason: .observerFailed,
            message: "The Messages database observer failed. Reconnect and refetch REST resources."
        )), observerRunID: runID)
    }

    private func observerFinished(observerRunID runID: UUID) {
        guard observerRunID == runID else { return }
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
        finishCurrentRun(observerRunID: runID)
    }

    private func finishCurrentRun(observerRunID runID: UUID) {
        guard observerRunID == runID else { return }
        observerRunID = nil
        observerTask = nil
        clearRun()
    }

    private func clearRun() {
        readyDelivery = nil
        eventRunID = nil
        nextSequence = 1
        history.removeAll(keepingCapacity: true)
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
