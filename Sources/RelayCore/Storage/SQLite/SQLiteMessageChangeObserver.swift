import Darwin
import Foundation
import SQLite3

public final class SQLiteMessageChangeObserver: MessageChangeObserving, @unchecked Sendable {
    private struct ObservedMessage: Equatable, Sendable {
        let rowID: Int64
        let messageID: MessageID
        let conversationID: ConversationID
        let isFromMe: Bool
        let deliveryState: DeliveryState
        let readState: ReadState
    }

    private struct ObservedReaction: Equatable, Sendable {
        let rowID: Int64
        let messageID: MessageID
        let reactionID: MessageID
        let action: ReactionAction
    }

    private struct MediaKey: Hashable, Sendable {
        let messageID: MessageID
        let mediaID: MediaID
    }

    private struct ObservedMedia: Sendable {
        let key: MediaKey
        let path: String?
    }

    private struct Snapshot: Sendable {
        let databaseIdentity: String
        let fileIdentity: String
        let dataVersion: Int64
        let messages: [MessageID: ObservedMessage]
        let reactions: [MessageID: ObservedReaction]
        let media: [MediaKey: ObservedMedia]
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var tasks: [UUID: Task<Void, Never>] = [:]
        var isShutdown = false
    }

    private let executor: SQLiteExecutor
    private let attachmentDirectory: URL
    private let fallbackPollInterval: Duration
    private let state = State()

    public init(
        path: String,
        attachmentDirectory: String,
        pollInterval: Duration = .seconds(5)
    ) {
        executor = SQLiteExecutor(path: path)
        self.attachmentDirectory = URL(fileURLWithPath: attachmentDirectory).standardizedFileURL
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

    private func observe(
        streamID: UUID,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) async {
        let triggers = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let fileMonitor = SQLiteFileChangeMonitor(path: executor.path) {
            triggers.continuation.yield()
        }
        let fallbackTask = fallbackTask(continuation: triggers.continuation)
        fileMonitor.start()
        defer {
            fallbackTask.cancel()
            fileMonitor.stop()
            triggers.continuation.finish()
            state.lock.withLock { state.tasks[streamID] = nil }
        }

        do {
            var previous = try await executor.run { database in
                try Self.snapshot(database: database)
            }
            continuation.yield(.streamReady(StreamReadyEvent(
                databaseIdentity: previous.databaseIdentity
            )))
            var pendingMedia = Set<MediaKey>()
            var availableMedia = Self.availableMedia(
                previous.media.values,
                attachmentDirectory: attachmentDirectory
            )
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

    private func fallbackTask(
        continuation: AsyncStream<Void>.Continuation
    ) -> Task<Void, Never> {
        Task { [fallbackPollInterval] in
            while !Task.isCancelled {
                do {
                    try await ContinuousClock().sleep(for: fallbackPollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                continuation.yield()
            }
        }
    }

    private func processChange(
        previous: inout Snapshot,
        pendingMedia: inout Set<MediaKey>,
        availableMedia: inout Set<MediaKey>,
        continuation: AsyncThrowingStream<RelayEvent, any Error>.Continuation
    ) async throws -> Bool {
        let check = try await executor.run { database in
            (try database.fileIdentity(), try database.dataVersion())
        }
        guard check.0 == previous.fileIdentity else {
            continuation.yield(.streamReset(StreamResetEvent(
                reason: .databaseChanged,
                message: "The Messages database changed. Reconnect and refetch REST resources."
            )))
            continuation.finish()
            return false
        }
        guard check.1 != previous.dataVersion || !pendingMedia.isEmpty else { return true }

        let current = try await executor.run { database in
            try Self.snapshot(database: database)
        }
        pendingMedia.formUnion(Set(current.media.keys).subtracting(previous.media.keys))
        pendingMedia.formIntersection(current.media.keys)
        let nowAvailable = Self.availableMedia(
            pendingMedia.compactMap { current.media[$0] },
            attachmentDirectory: attachmentDirectory
        )
        let newlyAvailable = nowAvailable.subtracting(availableMedia)
        for event in Self.events(
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

    public func shutdown() async throws {
        let tasks = state.lock.withLock { () -> [Task<Void, Never>] in
            state.isShutdown = true
            let tasks = Array(state.tasks.values)
            state.tasks.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        try await executor.shutdown()
    }

    private static func snapshot(database: SQLiteDatabase) throws -> Snapshot {
        return Snapshot(
            databaseIdentity: try database.identity(),
            fileIdentity: try database.fileIdentity(),
            dataVersion: try database.dataVersion(),
            messages: try messages(database: database),
            reactions: try reactions(database: database),
            media: try media(database: database)
        )
    }

    private static func messages(database: SQLiteDatabase) throws -> [MessageID: ObservedMessage] {
        let schema = database.schema
        let error = schema.expression("error", table: "message", alias: "m", fallback: "NULL")
        let sent = schema.expression("is_sent", table: "message", alias: "m", fallback: "NULL")
        let delivered = schema.expression("is_delivered", table: "message", alias: "m", fallback: "NULL")
        let read = schema.expression("is_read", table: "message", alias: "m", fallback: "NULL")
        let deliveredDate = schema.expression("date_delivered", table: "message", alias: "m", fallback: "NULL")
        let readDate = schema.expression("date_read", table: "message", alias: "m", fallback: "NULL")
        var sql = """
            SELECT m.ROWID, m.guid, c.guid, m.is_from_me, \(error), \(sent),
                   \(delivered), \(read), \(deliveredDate), \(readDate)
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            WHERE 1 = 1
            """
        if schema.hasColumn("associated_message_type", in: "message") {
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 2000 AND 2006)"
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 3000 AND 3006)"
        }
        if schema.hasColumn("filter_action", in: "chat_message_join") {
            sql += " AND cmj.filter_action = 0"
        }
        sql += " ORDER BY m.ROWID, c.ROWID"

        return try database.withStatement(sql) { statement in
            var values: [MessageID: ObservedMessage] = [:]
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    let messageID = try MessageID(validating: SQLiteValue.text(statement, 1))
                    guard values[messageID] == nil else { continue }
                    let isFromMe = sqlite3_column_int64(statement, 3) != 0
                    let row = MessageRow(
                        rowID: sqlite3_column_int64(statement, 0),
                        guid: messageID.rawValue,
                        conversationGUID: try SQLiteValue.text(statement, 2),
                        text: nil,
                        attributedBody: nil,
                        handle: nil,
                        originalHandle: nil,
                        isFromMe: isFromMe,
                        date: nil,
                        error: SQLiteValue.optionalInt64(statement, 4),
                        isSent: SQLiteRows.bool(statement, 5),
                        isDelivered: SQLiteRows.bool(statement, 6),
                        isRead: SQLiteRows.bool(statement, 7),
                        dateDelivered: SQLiteNumber.read(statement, 8),
                        dateRead: SQLiteNumber.read(statement, 9),
                        replyToGUID: nil,
                        threadOriginatorGUID: nil,
                        partCount: nil
                    )
                    values[messageID] = ObservedMessage(
                        rowID: row.rowID,
                        messageID: messageID,
                        conversationID: try ConversationID(validating: row.conversationGUID),
                        isFromMe: isFromMe,
                        deliveryState: SQLiteRows.deliveryState(row),
                        readState: SQLiteRows.readState(row)
                    )
                case SQLITE_DONE: return values
                default: throw SQLiteStorageError.queryFailed(database.lastError())
                }
            }
        }
    }

    private static func reactions(database: SQLiteDatabase) throws -> [MessageID: ObservedReaction] {
        let schema = database.schema
        guard schema.hasColumn("associated_message_guid", in: "message"),
              schema.hasColumn("associated_message_type", in: "message") else { return [:] }
        let normalizedTarget = """
            CASE
              WHEN r.associated_message_guid LIKE 'p:%/%'
                THEN substr(r.associated_message_guid, instr(r.associated_message_guid, '/') + 1)
              WHEN r.associated_message_guid LIKE 'bp:%'
                THEN substr(r.associated_message_guid, 4)
              ELSE r.associated_message_guid
            END
            """
        return try database.withStatement("""
            SELECT r.ROWID, r.guid, \(normalizedTarget), r.associated_message_type
            FROM message r
            JOIN message target ON target.guid = \(normalizedTarget)
            WHERE (r.associated_message_type BETWEEN 2000 AND 2006)
               OR (r.associated_message_type BETWEEN 3000 AND 3006)
            ORDER BY r.ROWID
            """) { statement in
                var values: [MessageID: ObservedReaction] = [:]
                while true {
                    switch sqlite3_step(statement) {
                    case SQLITE_ROW:
                        let reactionID = try MessageID(validating: SQLiteValue.text(statement, 1))
                        values[reactionID] = ObservedReaction(
                            rowID: sqlite3_column_int64(statement, 0),
                            messageID: try MessageID(validating: SQLiteValue.text(statement, 2)),
                            reactionID: reactionID,
                            action: sqlite3_column_int64(statement, 3) >= 3000 ? .removed : .added
                        )
                    case SQLITE_DONE: return values
                    default: throw SQLiteStorageError.queryFailed(database.lastError())
                    }
                }
            }
    }

    private static func media(database: SQLiteDatabase) throws -> [MediaKey: ObservedMedia] {
        try database.withStatement("""
            SELECT m.guid, a.guid, a.filename
            FROM message_attachment_join maj
            JOIN message m ON m.ROWID = maj.message_id
            JOIN attachment a ON a.ROWID = maj.attachment_id
            ORDER BY maj.message_id, maj.attachment_id
            """) { statement in
                var values: [MediaKey: ObservedMedia] = [:]
                while true {
                    switch sqlite3_step(statement) {
                    case SQLITE_ROW:
                        let key = MediaKey(
                            messageID: try MessageID(validating: SQLiteValue.text(statement, 0)),
                            mediaID: try MediaID(validating: SQLiteValue.text(statement, 1))
                        )
                        values[key] = ObservedMedia(
                            key: key,
                            path: SQLiteValue.optionalText(statement, 2)
                        )
                    case SQLITE_DONE: return values
                    default: throw SQLiteStorageError.queryFailed(database.lastError())
                    }
                }
            }
    }

    private static func availableMedia(
        _ media: some Sequence<ObservedMedia>,
        attachmentDirectory: URL
    ) -> Set<MediaKey> {
        Set(media.compactMap { value in
            guard let path = value.path else { return nil }
            let expanded = (path as NSString).expandingTildeInPath
            guard let opened = openRegularFile(path: expanded, within: attachmentDirectory) else {
                return nil
            }
            close(opened.descriptor)
            return value.key
        })
    }

    private static func events(
        from previous: Snapshot,
        to current: Snapshot,
        newlyAvailableMedia: Set<MediaKey>,
        observedAt: Timestamp
    ) -> [RelayEvent] {
        var values: [RelayEvent] = []
        let newMessages = current.messages.values
            .filter { previous.messages[$0.messageID] == nil }
            .sorted { $0.rowID < $1.rowID }
        values += newMessages.map {
            .messageCreated(MessageCreatedEvent(
                messageID: $0.messageID,
                conversationID: $0.conversationID,
                isFromMe: $0.isFromMe,
                observedAt: observedAt
            ))
        }

        let updatedMessages = current.messages.values
            .compactMap { currentValue -> (ObservedMessage, [MessageChangedField])? in
                guard let oldValue = previous.messages[currentValue.messageID] else { return nil }
                var fields: [MessageChangedField] = []
                if oldValue.deliveryState != currentValue.deliveryState { fields.append(.deliveryState) }
                if oldValue.readState != currentValue.readState { fields.append(.readState) }
                return fields.isEmpty ? nil : (currentValue, fields)
            }
            .sorted { $0.0.rowID < $1.0.rowID }
        values += updatedMessages.map {
            .messageUpdated(MessageUpdatedEvent(
                messageID: $0.0.messageID,
                conversationID: $0.0.conversationID,
                changedFields: $0.1,
                observedAt: observedAt
            ))
        }

        let newReactions = current.reactions.values
            .filter { previous.reactions[$0.reactionID] == nil }
            .sorted { $0.rowID < $1.rowID }
        values += newReactions.map {
            let payload = ReactionChangedEvent(
                messageID: $0.messageID,
                reactionID: $0.reactionID,
                observedAt: observedAt
            )
            return $0.action == .added ? .reactionAdded(payload) : .reactionRemoved(payload)
        }

        let availableMedia = newlyAvailableMedia.sorted {
            ($0.messageID.rawValue, $0.mediaID.rawValue)
                < ($1.messageID.rawValue, $1.mediaID.rawValue)
        }
        values += availableMedia.map {
            .mediaAvailable(MediaAvailableEvent(
                messageID: $0.messageID,
                mediaID: $0.mediaID,
                observedAt: observedAt
            ))
        }
        return values
    }
}
