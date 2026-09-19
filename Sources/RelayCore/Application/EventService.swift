import Foundation

public actor EventService {
    private let observer: any MessageChangeObserving
    private let subscriberBufferSize: Int
    private var subscribers: [UUID: AsyncStream<RelayEvent>.Continuation] = [:]
    private var observerTask: Task<Void, Never>?
    private var observerRunID: UUID?
    private var readyEvent: RelayEvent?

    public init(
        observer: any MessageChangeObserving,
        subscriberBufferSize: Int = 256
    ) {
        self.observer = observer
        self.subscriberBufferSize = max(1, subscriberBufferSize)
    }

    public func events() -> AsyncStream<RelayEvent> {
        let subscriberID = UUID()
        let pair = AsyncStream.makeStream(
            of: RelayEvent.self,
            bufferingPolicy: .bufferingNewest(subscriberBufferSize)
        )
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(subscriberID) }
        }
        subscribers[subscriberID] = pair.continuation
        if let readyEvent {
            pair.continuation.yield(readyEvent)
        }
        if observerTask == nil { startObserver() }
        return pair.stream
    }

    public func shutdown() async {
        let task = observerTask
        observerRunID = nil
        observerTask = nil
        readyEvent = nil
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
                    await self.publish(event, runID: runID)
                }
                await self?.observerFinished(runID: runID)
            } catch is CancellationError {
                await self?.observerFinished(runID: runID)
            } catch {
                await self?.observerFailed(error, runID: runID)
            }
        }
    }

    private func publish(_ event: RelayEvent, runID: UUID) {
        guard observerRunID == runID else { return }
        if case .streamReady = event { readyEvent = event }

        var overflowed: [UUID] = []
        var terminated: [UUID] = []
        for (id, continuation) in subscribers {
            switch continuation.yield(event) {
            case .enqueued: break
            case .dropped: overflowed.append(id)
            case .terminated: terminated.append(id)
            @unknown default: terminated.append(id)
            }
        }
        for id in terminated { subscribers[id] = nil }
        for id in overflowed {
            guard let continuation = subscribers.removeValue(forKey: id) else { continue }
            continuation.yield(.streamReset(StreamResetEvent(
                reason: .subscriberOverflow,
                message: "The event client fell behind. Reconnect and refetch REST resources."
            )))
            continuation.finish()
        }
        if case .streamReset = event {
            subscribers.values.forEach { $0.finish() }
            subscribers.removeAll()
            finishCurrentRun(runID: runID)
            return
        }
        stopObserverIfUnused()
    }

    private func observerFailed(_: any Error, runID: UUID) {
        guard observerRunID == runID else { return }
        let reset = RelayEvent.streamReset(StreamResetEvent(
            reason: .observerFailed,
            message: "The Messages database observer failed. Reconnect and refetch REST resources."
        ))
        for continuation in subscribers.values {
            continuation.yield(reset)
            continuation.finish()
        }
        subscribers.removeAll()
        finishCurrentRun(runID: runID)
    }

    private func observerFinished(runID: UUID) {
        guard observerRunID == runID else { return }
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
        finishCurrentRun(runID: runID)
    }

    private func finishCurrentRun(runID: UUID) {
        guard observerRunID == runID else { return }
        observerRunID = nil
        observerTask = nil
        readyEvent = nil
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
        stopObserverIfUnused()
    }

    private func stopObserverIfUnused() {
        guard subscribers.isEmpty else { return }
        let task = observerTask
        observerRunID = nil
        observerTask = nil
        readyEvent = nil
        task?.cancel()
    }
}
