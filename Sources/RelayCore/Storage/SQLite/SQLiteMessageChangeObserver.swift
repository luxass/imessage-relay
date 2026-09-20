import Foundation

public final class SQLiteMessageChangeObserver: MessageChangeObserving, @unchecked Sendable {
    struct Diagnostics: Equatable, Sendable {
        var incrementalBatches = 0
        var candidateRows = 0
        var readUpdateRows = 0
        var deliveryUpdateRows = 0
        var targetedRows = 0
        var mediaRows = 0
        var pendingMessageChecks = 0
        var pendingMessageEvictions = 0
        var pendingMessageExpirations = 0
        var pendingMediaChecks = 0
        var reconciliations = 0
        var pendingMediaEvictions = 0
        var pendingMediaExpirations = 0
    }

    private typealias Snapshot = SQLiteEventSnapshotStore.Snapshot
    private typealias MediaKey = SQLiteEventSnapshotStore.MediaKey

    private struct ObservationState {
        var previous: Snapshot
        var pendingMessages: [Int64: Date]
        var pendingMessageOffset: Int
        var pendingMedia: [MediaKey: Date]
        var pendingMediaOffset: Int
        var availableMedia: Set<MediaKey>
        var drainingBacklog: Bool
        var nextTargetedCheck: ContinuousClock.Instant
        var nextReconciliation: ContinuousClock.Instant
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var tasks: [UUID: Task<Void, Never>] = [:]
        var diagnostics = Diagnostics()
        var isShutdown = false
    }

    private let snapshotStore: SQLiteEventSnapshotStore
    private let fallbackPollInterval: Duration
    private let reconciliationInterval: Duration
    private let incrementalBatchSize: Int
    private let pendingMessageBatchSize: Int
    private let pendingMessageCapacity: Int
    private let pendingMessageRetention: TimeInterval
    private let pendingMediaBatchSize: Int
    private let pendingMediaCapacity: Int
    private let pendingMediaRetention: TimeInterval
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
        reconciliationInterval = .seconds(300)
        incrementalBatchSize = 256
        pendingMessageBatchSize = 64
        pendingMessageCapacity = 512
        pendingMessageRetention = 30 * 60
        pendingMediaBatchSize = 64
        pendingMediaCapacity = 512
        pendingMediaRetention = 30 * 60
    }

    init(
        path: String,
        attachmentDirectory: String,
        pollInterval: Duration,
        reconciliationInterval: Duration,
        incrementalBatchSize: Int = 256,
        pendingMediaBatchSize: Int = 64,
        pendingMediaCapacity: Int = 512,
        pendingMediaRetention: TimeInterval = 30 * 60
    ) {
        snapshotStore = SQLiteEventSnapshotStore(
            path: path,
            attachmentDirectory: attachmentDirectory
        )
        fallbackPollInterval = pollInterval > .zero ? pollInterval : .seconds(5)
        self.reconciliationInterval = reconciliationInterval > .zero
            ? reconciliationInterval
            : .seconds(300)
        self.incrementalBatchSize = max(1, incrementalBatchSize)
        pendingMessageBatchSize = 64
        pendingMessageCapacity = 512
        pendingMessageRetention = 30 * 60
        self.pendingMediaBatchSize = max(1, pendingMediaBatchSize)
        self.pendingMediaCapacity = max(1, pendingMediaCapacity)
        self.pendingMediaRetention = max(0, pendingMediaRetention)
    }

    var diagnostics: Diagnostics {
        state.lock.withLock { state.diagnostics }
    }

    private var periodicCheckInterval: Duration {
        max(fallbackPollInterval, .milliseconds(100))
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
        let fallbackTask = timerTask(interval: periodicCheckInterval) {
            fileMonitor.reconcile()
            triggers.continuation.yield()
        }
        let reconciliationTask = timerTask(interval: reconciliationInterval) {
            triggers.continuation.yield()
        }
        defer {
            fallbackTask.cancel()
            reconciliationTask.cancel()
            fileMonitor.stop()
            triggers.continuation.finish()
            state.lock.withLock { state.tasks[streamID] = nil }
        }

        do {
            let previous = try await initialSnapshot()
            let availableMedia = snapshotStore.availableMedia(previous.media.values)
            let pendingAtStartup = Set(previous.media.keys).subtracting(availableMedia)
            let clock = ContinuousClock()
            var observation = ObservationState(
                previous: previous,
                pendingMessages: [:],
                pendingMessageOffset: 0,
                pendingMedia: Dictionary(
                    uniqueKeysWithValues: pendingAtStartup.map { ($0, Date()) }
                ),
                pendingMediaOffset: 0,
                availableMedia: availableMedia,
                drainingBacklog: false,
                nextTargetedCheck: clock.now.advanced(by: periodicCheckInterval),
                nextReconciliation: clock.now.advanced(by: reconciliationInterval)
            )
            continuation.yield(.streamReady(StreamReadyEvent(
                databaseIdentity: observation.previous.databaseIdentity
            )))
            for await _ in triggers.stream {
                try Task.checkCancellation()
                let result = try await processChange(
                    observation: &observation,
                    continuation: continuation
                )
                guard result.shouldContinue else { return }
                if result.hasMore { triggers.continuation.yield() }
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

    private func timerTask(
        interval: Duration,
        onTimer: @escaping @Sendable () -> Void
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                do {
                    try await ContinuousClock().sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                onTimer()
            }
        }
    }

    private func processChange(
        observation: inout ObservationState,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) async throws -> (shouldContinue: Bool, hasMore: Bool) {
        guard let databaseState = try await snapshotStore.databaseState(),
              databaseState.fileIdentity == observation.previous.fileIdentity else {
            try? await snapshotStore.resetDatabaseConnection()
            return (finishForDatabaseChange(continuation), false)
        }

        let clock = ContinuousClock()
        if clock.now >= observation.nextReconciliation {
            guard try await reconcile(
                observation: &observation,
                clock: clock,
                continuation: continuation
            ) else {
                try? await snapshotStore.resetDatabaseConnection()
                return (finishForDatabaseChange(continuation), false)
            }
            return (true, false)
        }

        guard let incremental = try await readIncrementalChanges(
            databaseState: databaseState,
            observation: &observation,
            continuation: continuation
        ) else {
            try? await snapshotStore.resetDatabaseConnection()
            return (finishForDatabaseChange(continuation), false)
        }
        guard try await runTargetedRecheck(
            observation: &observation,
            clock: clock,
            continuation: continuation
        ), try await retryPendingMessages(
            observation: &observation,
            continuation: continuation
        ), try await checkPendingMedia(
            immediate: incremental.immediateMedia,
            observation: &observation,
            continuation: continuation
        ) else {
            try? await snapshotStore.resetDatabaseConnection()
            return (finishForDatabaseChange(continuation), false)
        }
        return (true, incremental.hasMore)
    }

    private func reconcile(
        observation: inout ObservationState,
        clock: ContinuousClock,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) async throws -> Bool {
        guard case .snapshot(let current) = try await snapshotStore.snapshot(
            expectedFileIdentity: observation.previous.fileIdentity
        ), current.fileIdentity == observation.previous.fileIdentity else { return false }
        state.lock.withLock { state.diagnostics.reconciliations += 1 }
        let now = Date()
        let unresolvedMedia = Set(current.media.keys).subtracting(observation.availableMedia)
        let nowAvailable = snapshotStore.availableMedia(
            unresolvedMedia.compactMap { current.media[$0] }
        )
        for key in unresolvedMedia.subtracting(nowAvailable) {
            observation.pendingMedia[key] = observation.pendingMedia[key] ?? now
        }
        observation.pendingMedia = observation.pendingMedia.filter { current.media[$0.key] != nil }
        for key in nowAvailable { observation.pendingMedia[key] = nil }
        trimPendingMedia(&observation.pendingMedia, now: now)
        let mappedRows = Set(current.messages.values.map(\.rowID))
            .union(current.reactions.values.map(\.rowID))
        for rowID in mappedRows { observation.pendingMessages[rowID] = nil }
        trimPendingMessages(&observation.pendingMessages, now: now)
        let newlyAvailable = nowAvailable.subtracting(observation.availableMedia)
        for event in SQLiteEventSnapshotStore.events(
            from: observation.previous,
            to: current,
            newlyAvailableMedia: newlyAvailable,
            observedAt: Timestamp(now)
        ) {
            continuation.yield(event)
        }
        observation.availableMedia.formIntersection(current.media.keys)
        observation.availableMedia.formUnion(nowAvailable)
        observation.previous = current
        observation.drainingBacklog = false
        observation.nextTargetedCheck = clock.now.advanced(by: periodicCheckInterval)
        observation.nextReconciliation = clock.now.advanced(by: reconciliationInterval)
        return true
    }

    private func readIncrementalChanges(
        databaseState: SQLiteEventSnapshotStore.DatabaseState,
        observation: inout ObservationState,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) async throws -> (immediateMedia: Set<MediaKey>, hasMore: Bool)? {
        guard databaseState.dataVersion != observation.previous.dataVersion
                || observation.drainingBacklog else {
            return ([], false)
        }
        let result = try await snapshotStore.incrementalBatch(
            positions: observation.previous.positions,
            limit: incrementalBatchSize,
            expectedFileIdentity: observation.previous.fileIdentity
        )
        guard case .value(let batch) = result else { return nil }
        state.lock.withLock {
            state.diagnostics.incrementalBatches += 1
            state.diagnostics.candidateRows += batch.candidates.count
            state.diagnostics.readUpdateRows += batch.readUpdates.count
            state.diagnostics.deliveryUpdateRows += batch.deliveryUpdates.count
            state.diagnostics.mediaRows += batch.media.count
        }
        apply(batch, to: &observation, continuation: continuation)
        observation.drainingBacklog = batch.hasMore
        return (Set(batch.media.map(\.key)), batch.hasMore)
    }

    private func runTargetedRecheck(
        observation: inout ObservationState,
        clock: ContinuousClock,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) async throws -> Bool {
        guard clock.now >= observation.nextTargetedCheck else { return true }
        let result = try await snapshotStore.targetedBatch(
            after: observation.previous.positions.targetedRowID,
            limit: incrementalBatchSize,
            expectedFileIdentity: observation.previous.fileIdentity
        )
        guard case .value(let batch) = result else { return false }
        state.lock.withLock { state.diagnostics.targetedRows += batch.candidates.count }
        applyCandidates(
            batch.candidates,
            updates: [],
            to: &observation,
            continuation: continuation
        )
        observation.previous.positions.targetedRowID = batch.nextRowID
        observation.nextTargetedCheck = clock.now.advanced(by: periodicCheckInterval)
        return true
    }

    private func retryPendingMessages(
        observation: inout ObservationState,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) async throws -> Bool {
        trimPendingMessages(&observation.pendingMessages, now: Date())
        let selectedRows = rotatedSelection(
            from: observation.pendingMessages.keys.sorted(),
            offset: &observation.pendingMessageOffset,
            limit: pendingMessageBatchSize
        )
        guard !selectedRows.isEmpty else { return true }
        state.lock.withLock { state.diagnostics.pendingMessageChecks += selectedRows.count }
        let result = try await snapshotStore.refreshMessageCandidates(
            rowIDs: selectedRows,
            expectedFileIdentity: observation.previous.fileIdentity
        )
        guard case .value(let candidates) = result else { return false }
        applyCandidates(
            candidates,
            updates: [],
            to: &observation,
            continuation: continuation
        )
        return true
    }

    private func checkPendingMedia(
        immediate: Set<MediaKey>,
        observation: inout ObservationState,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) async throws -> Bool {
        emitAvailableMedia(
            immediate,
            observation: &observation,
            continuation: continuation
        )
        trimPendingMedia(&observation.pendingMedia, now: Date())
        let selectedKeys = rotatedSelection(
            from: observation.pendingMedia.keys.sorted(by: mediaOrder),
            offset: &observation.pendingMediaOffset,
            limit: pendingMediaBatchSize
        )
        if !selectedKeys.isEmpty {
            state.lock.withLock { state.diagnostics.pendingMediaChecks += selectedKeys.count }
        }
        let missingPaths = selectedKeys.filter { observation.previous.media[$0]?.path == nil }
        let result = try await snapshotStore.refreshMedia(
            missingPaths,
            expectedFileIdentity: observation.previous.fileIdentity
        )
        guard case .value(let refreshedMedia) = result else { return false }
        for media in refreshedMedia { observation.previous.media[media.key] = media }
        emitAvailableMedia(
            Set(selectedKeys),
            observation: &observation,
            continuation: continuation
        )
        return true
    }

    private func apply(
        _ batch: SQLiteEventSnapshotStore.IncrementalBatch,
        to observation: inout ObservationState,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) {
        applyCandidates(
            batch.candidates,
            updates: batch.readUpdates + batch.deliveryUpdates,
            to: &observation,
            continuation: continuation
        )
        for media in batch.media {
            observation.previous.media[media.key] = media
            observation.pendingMedia[media.key] = observation.pendingMedia[media.key] ?? Date()
        }
        observation.previous.dataVersion = batch.dataVersion
        observation.previous.positions = batch.positions
    }

    private func applyCandidates(
        _ candidates: [SQLiteEventSnapshotStore.MessageCandidate],
        updates additionalUpdates: [SQLiteEventSnapshotStore.ObservedMessage],
        to observation: inout ObservationState,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) {
        let observedAt = Timestamp(Date())
        var updates: [MessageID: SQLiteEventSnapshotStore.ObservedMessage] = [:]
        for candidate in candidates.sorted(by: { $0.rowID < $1.rowID }) {
            if candidate.message == nil, candidate.reaction == nil {
                observation.pendingMessages[candidate.rowID]
                    = observation.pendingMessages[candidate.rowID] ?? Date()
            } else {
                observation.pendingMessages[candidate.rowID] = nil
            }
            if let message = candidate.message {
                if observation.previous.messages[message.messageID] == nil {
                    continuation.yield(.messageCreated(MessageCreatedEvent(
                        messageID: message.messageID,
                        conversationID: message.conversationID,
                        isFromMe: message.isFromMe,
                        observedAt: observedAt
                    )))
                    observation.previous.messages[message.messageID] = message
                } else {
                    updates[message.messageID] = message
                }
            }
            if let reaction = candidate.reaction,
               observation.previous.reactions[reaction.reactionID] == nil {
                let payload = ReactionChangedEvent(
                    messageID: reaction.messageID,
                    reactionID: reaction.reactionID,
                    observedAt: observedAt
                )
                continuation.yield(
                    reaction.action == .added ? .reactionAdded(payload) : .reactionRemoved(payload)
                )
                observation.previous.reactions[reaction.reactionID] = reaction
            }
        }
        for message in additionalUpdates {
            observation.pendingMessages[message.rowID] = nil
            updates[message.messageID] = message
        }
        for message in updates.values.sorted(by: { $0.rowID < $1.rowID }) {
            guard let old = observation.previous.messages[message.messageID] else {
                continuation.yield(.messageCreated(MessageCreatedEvent(
                    messageID: message.messageID,
                    conversationID: message.conversationID,
                    isFromMe: message.isFromMe,
                    observedAt: observedAt
                )))
                observation.previous.messages[message.messageID] = message
                continue
            }
            var fields: [MessageChangedField] = []
            if old.deliveryState != message.deliveryState { fields.append(.deliveryState) }
            if old.readState != message.readState { fields.append(.readState) }
            if !fields.isEmpty {
                continuation.yield(.messageUpdated(MessageUpdatedEvent(
                    messageID: message.messageID,
                    conversationID: message.conversationID,
                    changedFields: fields,
                    observedAt: observedAt
                )))
            }
            observation.previous.messages[message.messageID] = message
        }
    }

    private func emitAvailableMedia(
        _ keys: Set<MediaKey>,
        observation: inout ObservationState,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) {
        let nowAvailable = snapshotStore.availableMedia(
            keys.compactMap { observation.previous.media[$0] }
        )
        let newlyAvailable = nowAvailable.subtracting(observation.availableMedia)
        let observedAt = Timestamp(Date())
        for key in newlyAvailable.sorted(by: mediaOrder) {
            continuation.yield(.mediaAvailable(MediaAvailableEvent(
                messageID: key.messageID,
                mediaID: key.mediaID,
                observedAt: observedAt
            )))
        }
        observation.availableMedia.formUnion(nowAvailable)
        for key in nowAvailable { observation.pendingMedia[key] = nil }
    }

    private func rotatedSelection<Element>(
        from values: [Element],
        offset: inout Int,
        limit: Int
    ) -> [Element] {
        guard !values.isEmpty else {
            offset = 0
            return []
        }
        let count = min(limit, values.count)
        let selected = (0..<count).map { values[(offset + $0) % values.count] }
        offset = (offset + count) % values.count
        return selected
    }

    private func trimPendingMessages(
        _ pendingMessages: inout [Int64: Date],
        now: Date
    ) {
        let expired = pendingMessages.filter {
            now.timeIntervalSince($0.value) >= pendingMessageRetention
        }.map(\.key)
        for rowID in expired { pendingMessages[rowID] = nil }
        if !expired.isEmpty {
            state.lock.withLock { state.diagnostics.pendingMessageExpirations += expired.count }
        }
        guard pendingMessages.count > pendingMessageCapacity else { return }
        let evicted = pendingMessages.count - pendingMessageCapacity
        let retained = pendingMessages.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            return $0.key < $1.key
        }.prefix(pendingMessageCapacity)
        pendingMessages = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        state.lock.withLock { state.diagnostics.pendingMessageEvictions += evicted }
    }

    private func trimPendingMedia(
        _ pendingMedia: inout [MediaKey: Date],
        now: Date
    ) {
        let expired = pendingMedia.filter {
            now.timeIntervalSince($0.value) >= pendingMediaRetention
        }.map(\.key)
        for key in expired { pendingMedia[key] = nil }
        if !expired.isEmpty {
            state.lock.withLock { state.diagnostics.pendingMediaExpirations += expired.count }
        }
        guard pendingMedia.count > pendingMediaCapacity else { return }
        let evicted = pendingMedia.count - pendingMediaCapacity
        let retained = pendingMedia.sorted {
            if $0.value != $1.value { return $0.value < $1.value }
            return mediaOrder($0.key, $1.key)
        }.prefix(pendingMediaCapacity)
        pendingMedia = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        state.lock.withLock { state.diagnostics.pendingMediaEvictions += evicted }
    }

    private func mediaOrder(_ lhs: MediaKey, _ rhs: MediaKey) -> Bool {
        (lhs.messageID.rawValue, lhs.mediaID.rawValue)
            < (rhs.messageID.rawValue, rhs.mediaID.rawValue)
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
