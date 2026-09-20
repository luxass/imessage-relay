import Foundation

extension SQLiteMessageStore {
    private typealias SearchPosition = SearchPreviewCursor.Position

    private struct SearchContext {
        let conversationID: ConversationID
        let options: MessageListOptions
        let search: String
        let identity: String
        let signature: String
        let limit: Int
        let candidateBudget: Int
    }

    static func searchPage(
        database: SQLiteDatabase,
        conversationID: ConversationID,
        options: MessageListOptions,
        search: String,
        cursor: StorageCursor?,
        identity: String,
        signature: String,
        limit: Int
    ) throws -> PaginatedResponse<Message> {
        let context = SearchContext(
            conversationID: conversationID,
            options: options,
            search: search,
            identity: identity,
            signature: signature,
            limit: limit,
            candidateBudget: min(2_048, max(256, limit * 8))
        )
        guard let cursor, let preview = cursor.searchPreview else {
            return try searchCandidatePage(database: database, cursor: cursor, context: context)
        }
        switch preview.phase {
        case .resolving:
            return try resolvePreviewGroup(database: database, cursor: cursor, preview: preview, context: context)
        case .replayingStart, .replaying:
            return try replayStandalonePreviews(database: database, cursor: cursor, preview: preview, context: context)
        }
    }

    private static func searchCandidatePage(
        database: SQLiteDatabase,
        cursor: StorageCursor?,
        context: SearchContext
    ) throws -> PaginatedResponse<Message> {
        let raw = try searchRecords(database: database, cursor: cursor, limit: context.candidateBudget, context: context)
        let hasUnscanned = raw.count > context.candidateBudget
        let scanned = Array(raw.prefix(context.candidateBudget))
        let window = coalescedPreviewWindow(scanned, hasMore: hasUnscanned)
        let matches = window.records.filter { recordMatches($0, context: context) }
        let stoppedAtPageLimit = matches.count > context.limit
        let selected = Array(matches.prefix(context.limit))
        let pending = stoppedAtPageLimit ? nil : window.pending.map {
            SearchPreviewCursor(phase: .resolving, newest: position($0.newest), root: $0.root.map(position), end: nil)
        }
        return try searchResponse(
            database: database,
            selected: selected,
            continuation: (stoppedAtPageLimit ? selected.last : scanned.last).map(position),
            preview: pending,
            hasMore: stoppedAtPageLimit || hasUnscanned,
            context: context
        )
    }

    private static func resolvePreviewGroup(
        database: SQLiteDatabase,
        cursor: StorageCursor,
        preview: SearchPreviewCursor,
        context: SearchContext
    ) throws -> PaginatedResponse<Message> {
        let newest = try previewRecord(database: database, at: preview.newest, context: context)
        guard isURLPreview(newest) else { throw SQLiteStorageError.invalidCursor }
        var group = URLPreviewGroup(newest: newest)
        group.root = try preview.root.map { try previewRecord(database: database, at: $0, context: context) }
        if let root = group.root {
            guard sameSender(newest, root), containsURL(root.message.text) else {
                throw SQLiteStorageError.invalidCursor
            }
        }
        let raw = try searchRecords(database: database, cursor: cursor, limit: context.candidateBudget, context: context)
        var end = SearchPosition(date: cursor.date, rowID: cursor.rowID)
        for (index, candidate) in raw.prefix(context.candidateBudget).enumerated() {
            guard group.appendOlder(candidate) else {
                return try resolvedPreviewResponse(
                    database: database, group: group, end: end, hasMore: true, context: context
                )
            }
            end = position(candidate)
            if !isURLPreview(candidate) {
                return try resolvedPreviewResponse(
                    database: database, group: group, end: end, hasMore: index + 1 < raw.count, context: context
                )
            }
        }
        if raw.count > context.candidateBudget {
            return try searchResponse(
                database: database,
                selected: [],
                continuation: end,
                preview: SearchPreviewCursor(
                    phase: .resolving, newest: preview.newest, root: group.root.map(position), end: nil
                ),
                hasMore: true,
                context: context
            )
        }
        return try resolvedPreviewResponse(database: database, group: group, end: end, hasMore: false, context: context)
    }

    private static func resolvedPreviewResponse(
        database: SQLiteDatabase,
        group: URLPreviewGroup,
        end: SearchPosition,
        hasMore: Bool,
        context: SearchContext
    ) throws -> PaginatedResponse<Message> {
        // Only URL-less previews older than the root need replay. Their logical
        // status is now known, so replay never makes its own coalescing decisions.
        let root = group.logicalRoot
        let single = end == position(group.newest)
        let logical = root ?? (single ? group.newest : nil)
        let continuation = logical.map(position) ?? position(group.newest)
        let needsReplay = logical == nil || continuation != end
        let replay = needsReplay ? SearchPreviewCursor(
            phase: root == nil ? .replayingStart : .replaying,
            newest: position(group.newest),
            root: root.map(position),
            end: end
        ) : nil
        return try searchResponse(
            database: database,
            selected: logical.map { recordMatches($0, context: context) ? [$0] : [] } ?? [],
            continuation: continuation,
            preview: replay,
            hasMore: needsReplay || hasMore,
            context: context
        )
    }

    private static func replayStandalonePreviews(
        database: SQLiteDatabase,
        cursor: StorageCursor,
        preview: SearchPreviewCursor,
        context: SearchContext
    ) throws -> PaginatedResponse<Message> {
        let newest = try previewRecord(database: database, at: preview.newest, context: context)
        var raw: [Record] = preview.phase == .replayingStart ? [newest] : []
        raw += try searchRecords(
            database: database,
            cursor: cursor,
            limit: context.candidateBudget - raw.count,
            context: context
        )
        var selected: [Record] = []
        var consumed: SearchPosition?
        for (index, candidate) in raw.prefix(context.candidateBudget).enumerated() {
            guard isURLPreview(candidate), sameSender(candidate, newest), !containsURL(candidate.message.text) else {
                throw SQLiteStorageError.invalidCursor
            }
            consumed = position(candidate)
            if recordMatches(candidate, context: context) { selected.append(candidate) }
            let reachedEnd = consumed == preview.end
            if reachedEnd || selected.count == context.limit {
                return try searchResponse(
                    database: database,
                    selected: selected,
                    continuation: consumed,
                    preview: reachedEnd ? nil : replayCursor(preview),
                    hasMore: !reachedEnd || index + 1 < raw.count,
                    context: context
                )
            }
        }
        guard let consumed, raw.count > context.candidateBudget else {
            throw SQLiteStorageError.invalidCursor
        }
        return try searchResponse(
            database: database,
            selected: selected,
            continuation: consumed,
            preview: replayCursor(preview),
            hasMore: true,
            context: context
        )
    }

    private static func replayCursor(_ preview: SearchPreviewCursor) -> SearchPreviewCursor {
        SearchPreviewCursor(phase: .replaying, newest: preview.newest, root: preview.root, end: preview.end)
    }

    private static func position(_ record: Record) -> SearchPosition {
        SearchPosition(date: record.row.date, rowID: record.row.rowID)
    }

    private static func previewRecord(
        database: SQLiteDatabase,
        at position: SearchPosition,
        context: SearchContext
    ) throws -> Record {
        guard let record = try record(database: database, rowID: position.rowID, conversationID: context.conversationID),
              record.row.date == position.date else { throw SQLiteStorageError.invalidCursor }
        return record
    }

    private static func searchRecords(
        database: SQLiteDatabase,
        cursor: StorageCursor?,
        limit: Int,
        context: SearchContext
    ) throws -> [Record] {
        try records(
            database: database,
            sql: listSQL(schema: database.schema, cursor: cursor),
            query: RecordQuery(conversationID: context.conversationID, cursor: cursor, limit: limit)
        )
    }

    private static func searchResponse(
        database: SQLiteDatabase,
        selected: [Record],
        continuation: SearchPosition?,
        preview: SearchPreviewCursor?,
        hasMore: Bool,
        context: SearchContext
    ) throws -> PaginatedResponse<Message> {
        var selected = selected
        try hydrate(
            database: database,
            records: &selected,
            attachments: context.options.includeAttachments,
            reactions: true
        )
        let nextCursor = try hasMore ? continuation.map {
            try CursorCodec.encode(
                route: "conversation_messages",
                databaseIdentity: context.identity,
                querySignature: context.signature,
                date: $0.date,
                rowID: $0.rowID,
                searchPreview: preview
            )
        } : nil
        return PaginatedResponse(items: selected.map(\.message), nextCursor: nextCursor, hasMore: hasMore)
    }

    private static func recordMatches(_ record: Record, context: SearchContext) -> Bool {
        matches(record.message.text, search: context.search, mode: context.options.searchMode)
    }
}
