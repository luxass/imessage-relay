import Foundation

public final class SQLiteMessageChangeObserver: MessageChangeObserving, @unchecked Sendable {
    private typealias Snapshot = SQLiteEventSnapshotStore.Snapshot
    private typealias MediaKey = SQLiteEventSnapshotStore.MediaKey

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var tasks: [UUID: Task<Void, Never>] = [:]
        var isShutdown = false
    }

    private let snapshotStore: SQLiteEventSnapshotStore
    private let fallbackPollInterval: Duration
    private let state = State()

    public init(
        path: String,
        attachmentDirectory: String,
        pollInterval: Duration = .seconds(5)
    ) {
        snapshotStore = SQLiteEventSnapshotStore(
            path: path,
            attachmentDirectory: attachmentDirectory
        )
        fallbackPollInterval = pollInterval > .zero ? pollInterval : .seconds(5)
    }

    public func events() -> AsyncThrowingStream<RelayEvent, any Error> {
        let streamID = UUID()
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                await observe(streamID: streamID, continuation: continuation)
            }
            let accepted = state.lock.withLock { () -> Bool in
                guard !state.isShutdown else { return false }
                state.tasks[streamID] = task
                return true
            }
            if !accepted {
                task.cancel()
                continuation.finish(throwing: SQLiteStorageError.shutDown)
            }
            continuation.onTermination = { [state] _ in
                state.lock.withLock { state.tasks[streamID]?.cancel() }
            }
        }
    }

    public func shutdown() async throws {
        let tasks = state.lock.withLock { () -> [Task<Void, Never>] in
            state.isShutdown = true
            let tasks = Array(state.tasks.values)
            state.tasks.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        try await snapshotStore.shutdown()
    }

    private func observe(
        streamID: UUID,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) async {
        let triggers = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let fileMonitor = SQLiteFileChangeMonitor(path: snapshotStore.path) {
            triggers.continuation.yield()
        }
        fileMonitor.start()
        let fallbackTask = fallbackTask {
            fileMonitor.reconcile()
        }
        defer {
            fallbackTask.cancel()
            fileMonitor.stop()
            triggers.continuation.finish()
            state.lock.withLock { state.tasks[streamID] = nil }
        }

        do {
            var previous = try await initialSnapshot()
            continuation.yield(.streamReady(StreamReadyEvent(
                databaseIdentity: previous.databaseIdentity
            )))
            var pendingMedia = Set<MediaKey>()
            var availableMedia = snapshotStore.availableMedia(previous.media.values)
            for await _ in triggers.stream {
                try Task.checkCancellation()
                guard try await processChange(
                    previous: &previous,
                    pendingMedia: &pendingMedia,
                    availableMedia: &availableMedia,
                    continuation: continuation
                ) else { return }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func initialSnapshot() async throws -> Snapshot {
        while true {
            switch try await snapshotStore.snapshot() {
            case .snapshot(let snapshot):
                return snapshot
            case .databaseChanged:
                try await snapshotStore.resetDatabaseConnection()
            }
        }
    }

    private func fallbackTask(
        onFallback: @escaping @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task { [fallbackPollInterval] in
            while !Task.isCancelled {
                do {
                    try await ContinuousClock().sleep(for: fallbackPollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                onFallback()
            }
        }
    }

    private func processChange(
        previous: inout Snapshot,
        pendingMedia: inout Set<MediaKey>,
        availableMedia: inout Set<MediaKey>,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) async throws -> Bool {
        guard let databaseState = try await snapshotStore.databaseState(),
              databaseState.fileIdentity == previous.fileIdentity else {
            try? await snapshotStore.resetDatabaseConnection()
            return finishForDatabaseChange(continuation)
        }
        guard databaseState.dataVersion != previous.dataVersion || !pendingMedia.isEmpty else { return true }

        guard case .snapshot(let current) = try await snapshotStore.snapshot() else {
            try? await snapshotStore.resetDatabaseConnection()
            return finishForDatabaseChange(continuation)
        }
        pendingMedia.formUnion(Set(current.media.keys).subtracting(previous.media.keys))
        pendingMedia.formIntersection(current.media.keys)
        let nowAvailable = snapshotStore.availableMedia(
            pendingMedia.compactMap { current.media[$0] }
        )
        let newlyAvailable = nowAvailable.subtracting(availableMedia)
        for event in SQLiteEventSnapshotStore.events(
            from: previous,
            to: current,
            newlyAvailableMedia: newlyAvailable,
            observedAt: Timestamp(Date())
        ) {
            continuation.yield(event)
        }
        availableMedia.formUnion(nowAvailable)
        pendingMedia.subtract(nowAvailable)
        previous = current
        return true
    }

    private func finishForDatabaseChange(
        _ continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) -> Bool {
        continuation.yield(.streamReset(StreamResetEvent(
            reason: .databaseChanged,
            message: "The Messages database changed. Reconnect and refetch REST resources."
        )))
        continuation.finish()
        return false
    }
}
