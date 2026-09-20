import Foundation

extension SQLiteMessageStore {
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
            return try resolvePreviewGroup(
                database: database,
                cursor: cursor,
                preview: preview,
                context: context
            )
        case .replayingStart, .replaying:
            return try replayPreviewGroup(
                database: database,
                cursor: cursor,
                preview: preview,
                context: context
            )
        }
    }

    private static func searchCandidatePage(
        database: SQLiteDatabase,
        cursor: StorageCursor?,
        context: SearchContext
    ) throws -> PaginatedResponse<Message> {
        let raw = try searchRecords(
            database: database,
            cursor: cursor,
            limit: context.candidateBudget,
            context: context
        )
        let hasUnscanned = raw.count > context.candidateBudget
        let scanned = Array(raw.prefix(context.candidateBudget))
        if hasUnscanned,
           let groupRange = trailingPreviewRange(scanned) {
            let prefix = Array(scanned[..<groupRange.lowerBound])
            let matches = matchingRecords(coalesceURLPreviews(prefix), context: context)
            if matches.count > context.limit {
                return try searchResponse(
                    database: database,
                    selected: Array(matches.prefix(context.limit)),
                    continuation: matches[context.limit - 1],
                    preview: nil,
                    hasMore: true,
                    context: context
                )
            }
            let groupStart = scanned[groupRange.lowerBound]
            let scanEnd = scanned[groupRange.upperBound - 1]
            let preview = SearchPreviewCursor(
                phase: .resolving,
                groupStartDate: groupStart.row.date,
                groupStartRowID: groupStart.row.rowID,
                contextDate: nil,
                contextRowID: nil,
                selectedPreviewRowID: nil
            )
            return try searchResponse(
                database: database,
                selected: matches,
                continuation: scanEnd,
                preview: preview,
                hasMore: true,
                context: context
            )
        }

        let matches = matchingRecords(coalesceURLPreviews(scanned), context: context)
        let stoppedAtPageLimit = matches.count > context.limit
        let selected = Array(matches.prefix(context.limit))
        return try searchResponse(
            database: database,
            selected: selected,
            continuation: stoppedAtPageLimit
                ? selected.last
                : scanned.last ?? raw.prefix(context.candidateBudget).last,
            preview: nil,
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
        let raw = try searchRecords(
            database: database,
            cursor: cursor,
            limit: context.candidateBudget,
            context: context
        )
        let hasUnscanned = raw.count > context.candidateBudget
        let scanned = Array(raw.prefix(context.candidateBudget))
        if let resolved = scanned.first(where: { !isURLPreview($0) }) {
            return try previewTransitionResponse(
                database: database,
                preview: preview,
                contextRecord: resolved,
                context: context
            )
        }
        if hasUnscanned, let scanEnd = scanned.last {
            let resolving = SearchPreviewCursor(
                phase: .resolving,
                groupStartDate: preview.groupStartDate,
                groupStartRowID: preview.groupStartRowID,
                contextDate: nil,
                contextRowID: nil,
                selectedPreviewRowID: nil
            )
            return try searchResponse(
                database: database,
                selected: [],
                continuation: scanEnd,
                preview: resolving,
                hasMore: true,
                context: context
            )
        }
        return try previewTransitionResponse(
            database: database,
            preview: preview,
            contextRecord: nil,
            context: context
        )
    }

    private static func previewTransitionResponse(
        database: SQLiteDatabase,
        preview: SearchPreviewCursor,
        contextRecord: Record?,
        context: SearchContext
    ) throws -> PaginatedResponse<Message> {
        let replay = SearchPreviewCursor(
            phase: .replayingStart,
            groupStartDate: preview.groupStartDate,
            groupStartRowID: preview.groupStartRowID,
            contextDate: contextRecord?.row.date,
            contextRowID: contextRecord?.row.rowID,
            selectedPreviewRowID: nil
        )
        let continuation = try record(
            database: database,
            rowID: preview.groupStartRowID,
            conversationID: context.conversationID
        )
        guard let continuation,
              continuation.row.date == preview.groupStartDate,
              isURLPreview(continuation) else {
            throw SQLiteStorageError.invalidCursor
        }
        return try searchResponse(
            database: database,
            selected: [],
            continuation: continuation,
            preview: replay,
            hasMore: true,
            context: context
        )
    }

    private static func replayPreviewGroup(
        database: SQLiteDatabase,
        cursor: StorageCursor,
        preview: SearchPreviewCursor,
        context: SearchContext
    ) throws -> PaginatedResponse<Message> {
        let contextRecord = try preview.contextRowID.map {
            try record(database: database, rowID: $0, conversationID: context.conversationID)
        } ?? nil
        if preview.contextRowID != nil {
            guard let contextRecord,
                  contextRecord.row.date == preview.contextDate else {
                throw SQLiteStorageError.invalidCursor
            }
        }
        var raw: [Record] = []
        if preview.phase == .replayingStart {
            guard let first = try record(
                database: database,
                rowID: preview.groupStartRowID,
                conversationID: context.conversationID
            ), first.row.date == preview.groupStartDate, isURLPreview(first) else {
                throw SQLiteStorageError.invalidCursor
            }
            raw.append(first)
            raw += try searchRecords(
                database: database,
                cursor: storageCursor(for: first, from: cursor),
                limit: context.candidateBudget - 1,
                context: context
            )
        } else {
            raw = try searchRecords(
                database: database,
                cursor: cursor,
                limit: context.candidateBudget,
                context: context
            )
        }
        return try replayPreviewRecords(
            database: database,
            raw: raw,
            preview: preview,
            contextRecord: contextRecord,
            context: context
        )
    }

    private static func replayPreviewRecords(
        database: SQLiteDatabase,
        raw: [Record],
        preview: SearchPreviewCursor,
        contextRecord: Record?,
        context: SearchContext
    ) throws -> PaginatedResponse<Message> {
        let scanned = Array(raw.prefix(context.candidateBudget))
        var selected: [Record] = []
        var selectedPreviewRowID = preview.selectedPreviewRowID
        var consumed: Record?
        for (index, candidate) in scanned.enumerated() {
            if candidate.row.rowID == preview.contextRowID {
                if selected.count == context.limit, let consumed {
                    return try replayContinuation(
                        database: database,
                        selected: selected,
                        consumed: consumed,
                        preview: preview,
                        selectedPreviewRowID: selectedPreviewRowID,
                        context: context
                    )
                }
                var logical = candidate
                if let selectedPreviewRowID,
                   let previewRecord = try record(
                    database: database,
                    rowID: selectedPreviewRowID,
                    conversationID: context.conversationID
                   ) {
                    attachURLPreview(previewRecord, to: &logical)
                }
                if recordMatches(logical, context: context) { selected.append(logical) }
                let hasMore = index + 1 < raw.count
                return try searchResponse(
                    database: database,
                    selected: selected,
                    continuation: logical,
                    preview: nil,
                    hasMore: hasMore,
                    context: context
                )
            }
            guard isURLPreview(candidate) else { throw SQLiteStorageError.invalidCursor }
            if let contextRecord, canCoalesceURLPreview(candidate, with: contextRecord) {
                selectedPreviewRowID = selectedPreviewRowID ?? candidate.row.rowID
            } else if recordMatches(candidate, context: context) {
                selected.append(candidate)
            }
            consumed = candidate
            if selected.count == context.limit {
                let moreInGroup = index + 1 < raw.count || preview.contextRowID != nil
                if moreInGroup {
                    return try replayContinuation(
                        database: database,
                        selected: selected,
                        consumed: candidate,
                        preview: preview,
                        selectedPreviewRowID: selectedPreviewRowID,
                        context: context
                    )
                }
            }
        }
        guard let consumed else {
            throw SQLiteStorageError.invalidCursor
        }
        let hasUnscanned = raw.count > context.candidateBudget
        if contextRecord == nil, !hasUnscanned {
            return try searchResponse(
                database: database,
                selected: selected,
                continuation: consumed,
                preview: nil,
                hasMore: false,
                context: context
            )
        }
        return try replayContinuation(
            database: database,
            selected: selected,
            consumed: consumed,
            preview: preview,
            selectedPreviewRowID: selectedPreviewRowID,
            context: context
        )
    }

    private static func replayContinuation(
        database: SQLiteDatabase,
        selected: [Record],
        consumed: Record,
        preview: SearchPreviewCursor,
        selectedPreviewRowID: Int64?,
        context: SearchContext
    ) throws -> PaginatedResponse<Message> {
        let replay = SearchPreviewCursor(
            phase: .replaying,
            groupStartDate: preview.groupStartDate,
            groupStartRowID: preview.groupStartRowID,
            contextDate: preview.contextDate,
            contextRowID: preview.contextRowID,
            selectedPreviewRowID: selectedPreviewRowID
        )
        return try searchResponse(
            database: database,
            selected: selected,
            continuation: consumed,
            preview: replay,
            hasMore: true,
            context: context
        )
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
            query: RecordQuery(
                conversationID: context.conversationID,
                cursor: cursor,
                limit: limit
            )
        )
    }

    private static func searchResponse(
        database: SQLiteDatabase,
        selected: [Record],
        continuation: Record?,
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
                date: $0.row.date,
                rowID: $0.row.rowID,
                searchPreview: preview
            )
        } : nil
        return PaginatedResponse(
            items: selected.map(\.message),
            nextCursor: nextCursor,
            hasMore: hasMore
        )
    }

    private static func matchingRecords(
        _ records: [Record],
        context: SearchContext
    ) -> [Record] {
        records.filter { recordMatches($0, context: context) }
    }

    private static func recordMatches(_ record: Record, context: SearchContext) -> Bool {
        matches(record.message.text, search: context.search, mode: context.options.searchMode)
    }

    private static func trailingPreviewRange(_ records: [Record]) -> Range<Int>? {
        guard records.last.map(isURLPreview) == true else { return nil }
        var start = records.count - 1
        while start > 0, isURLPreview(records[start - 1]) { start -= 1 }
        return start..<records.count
    }

    private static func storageCursor(for record: Record, from cursor: StorageCursor) -> StorageCursor {
        StorageCursor(
            version: cursor.version,
            route: cursor.route,
            databaseIdentity: cursor.databaseIdentity,
            querySignature: cursor.querySignature,
            date: record.row.date,
            rowID: record.row.rowID,
            searchPreview: nil
        )
    }

}
