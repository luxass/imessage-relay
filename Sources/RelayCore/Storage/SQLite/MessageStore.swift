import Foundation

public final class SQLiteMessageStore: MessageStoring, SendCorrelating, Sendable {
    private struct AttachmentRecord: Sendable {
        let guid: String
        let reference: MediaReference
    }

    private struct Record: Sendable {
        let row: MessageRow
        var message: Message
    }

    private struct MediaMatch {
        let record: Record
        let attachment: MediaReference
    }

    private struct RecordQuery {
        let conversationID: ConversationID
        let cursor: StorageCursor?
        let hasSearch: Bool
        let limit: Int
    }

    private let executor: SQLiteExecutor

    init(executor: SQLiteExecutor) {
        self.executor = executor
    }

    public func listMessages(
        conversationID: ConversationID,
        options: MessageListOptions
    ) async throws -> PaginatedResponse<Message> {
        try await executor.run { database in
            try database.withReadTransaction {
                try Self.list(database: database, conversationID: conversationID, options: options)
            }
        }
    }

    public func message(id: MessageID) async throws -> Message? {
        try await executor.run { database in
            try database.withReadTransaction {
                guard var record = try Self.record(database: database, messageID: id) else { return nil }
                try Self.hydrate(database: database, records: &record, attachments: true, reactions: true)
                return record.message
            }
        }
    }

    public func checkpoint() async throws -> OutgoingMessageCheckpoint {
        try await executor.run { database in
            let rowID = try database.withStatement("SELECT COALESCE(MAX(ROWID), 0) FROM message") { statement in
                guard try statement.step() == .row else {
                    throw SQLiteStorageError.queryFailed("Message checkpoint query returned no row.")
                }
                return try statement.int64(0)
            }
            return OutgoingMessageCheckpoint(rowID: rowID)
        }
    }

    public func correlate(
        _ criteria: SendCorrelationCriteria
    ) async throws -> SendCorrelationOutcome {
        try await executor.run { database in
            try database.withReadTransaction {
                try Self.correlate(database: database, criteria: criteria)
            }
        }
    }

    private static func list(
        database: SQLiteDatabase,
        conversationID: ConversationID,
        options: MessageListOptions
    ) throws -> PaginatedResponse<Message> {
        guard try conversationExists(database: database, id: conversationID) else {
            throw RelayServiceError.unknownConversation
        }
        let limit = max(1, min(options.limit, 200))
        let search = normalizedSearch(options.search)
        let identity = try database.identity()
        let signature = querySignature(conversationID: conversationID, options: options, search: search)
        let cursor = try CursorCodec.decode(
            options.cursor,
            route: "conversation_messages",
            databaseIdentity: identity,
            querySignature: signature
        )
        var records = try records(
            database: database,
            sql: listSQL(schema: database.schema, cursor: cursor, hasSearch: search != nil),
            query: RecordQuery(
                conversationID: conversationID,
                cursor: cursor,
                hasSearch: search != nil,
                limit: limit * 2
            )
        )
        records = coalesceURLPreviews(records)
        if let search {
            records = records.filter { matches($0.message.text, search: search, mode: options.searchMode) }
        }
        let hasMore = records.count > limit
        records = Array(records.prefix(limit))
        try hydrate(
            database: database,
            records: &records,
            attachments: options.includeAttachments,
            reactions: true
        )
        let nextCursor = try hasMore ? records.last.map {
            try CursorCodec.encode(
                route: "conversation_messages",
                databaseIdentity: identity,
                querySignature: signature,
                date: $0.row.date,
                rowID: $0.row.rowID
            )
        } : nil
        return PaginatedResponse(
            items: records.map(\.message),
            nextCursor: nextCursor,
            hasMore: hasMore
        )
    }

    private static func correlate(
        database: SQLiteDatabase,
        criteria: SendCorrelationCriteria
    ) throws -> SendCorrelationOutcome {
        var records = try correlationRecords(
            database: database,
            checkpoint: criteria.checkpoint
        )
        if !criteria.media.isEmpty {
            try hydrate(database: database, records: &records, attachments: true, reactions: false)
        }

        records = try records.filter {
            try destinationMatches(
                database: database,
                message: $0.message,
                destination: criteria.destination,
                accountID: criteria.accountID
            )
        }
        let relationshipRecords = records.filter {
            threadMatches($0.row, criteria: criteria)
        }

        let textRecords: [Record]
        if let text = criteria.text {
            textRecords = relationshipRecords.filter {
                $0.message.text?.trimmingCharacters(in: .whitespacesAndNewlines) == text
            }
            if textRecords.count > 1 { return .ambiguous }
            if textRecords.isEmpty, records.contains(where: {
                $0.message.text?.trimmingCharacters(in: .whitespacesAndNewlines) == text
            }) {
                return .mismatched
            }
        } else {
            textRecords = []
        }

        let mediaRecords = relationshipRecords.filter { !$0.message.attachments.isEmpty }
        let textMediaRecords = textRecords.filter { !$0.message.attachments.isEmpty }
        let fallbackMediaRecord: Record?
        if textMediaRecords.count == 1 {
            fallbackMediaRecord = textMediaRecords[0]
        } else if mediaRecords.count == 1 {
            fallbackMediaRecord = mediaRecords[0]
        } else {
            fallbackMediaRecord = nil
        }
        guard let mediaResult = matchMedia(
            criteria.media,
            in: relationshipRecords,
            fallbackRecord: fallbackMediaRecord
        ) else {
            return .ambiguous
        }
        for (expected, receipt) in zip(criteria.media, mediaResult.receipts)
        where receipt.mediaID == nil && hasMediaCandidate(expected, in: records) {
            return .mismatched
        }

        var matchedRecordsByID: [MessageID: Record] = [:]
        for record in textRecords { matchedRecordsByID[record.message.id] = record }
        for match in mediaResult.matches { matchedRecordsByID[match.record.message.id] = match.record }
        let matchedMessages = matchedRecordsByID.values
            .sorted { $0.row.rowID < $1.row.rowID }
            .map(\.message)
        guard !matchedMessages.isEmpty else { return .pending }

        let textComplete = criteria.text == nil || textRecords.count == 1
        let mediaComplete = mediaResult.receipts.allSatisfy { $0.mediaID != nil && $0.messageID != nil }
        let snapshot = SendCorrelationSnapshot(messages: matchedMessages, media: mediaResult.receipts)
        return textComplete && mediaComplete ? .complete(snapshot) : .partial(snapshot)
    }

    private static func correlationRecords(
        database: SQLiteDatabase,
        checkpoint: OutgoingMessageCheckpoint
    ) throws -> [Record] {
        var sql = """
            SELECT \(projection(database.schema))
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.ROWID > ? AND m.is_from_me = 1
            """
        if database.schema.hasColumn("associated_message_type", in: "message") {
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 2000 AND 2006)"
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 3000 AND 3006)"
        }
        if database.schema.hasColumn("filter_action", in: "chat_message_join") {
            sql += " AND cmj.filter_action = 0"
        }
        sql += " ORDER BY m.ROWID ASC LIMIT 100"

        return try database.withStatement(sql) { statement in
            try statement.bind(checkpoint.rowID, at: 1)
            var values: [Record] = []
            while try statement.step() == .row {
                let row = try decode(statement)
                values.append(Record(row: row, message: try SQLiteRows.message(row)))
            }
            return values
        }
    }

    private static func hasMediaCandidate(
        _ expected: SendCorrelationMedia,
        in records: [Record]
    ) -> Bool {
        guard let filename = expected.filename else { return false }
        return records.contains { record in
            record.message.attachments.contains { $0.filename == filename }
        }
    }

    private static func matchMedia(
        _ expectedMedia: [SendCorrelationMedia],
        in records: [Record],
        fallbackRecord: Record?
    ) -> (receipts: [MediaReceipt], matches: [MediaMatch])? {
        var receipts: [MediaReceipt] = []
        var selected: [MediaMatch] = []
        let fallbackAttachments = fallbackRecord?.message.attachments ?? []
        for (index, expected) in expectedMedia.enumerated() {
            var matches: [MediaMatch]
            if let expectedFilename = expected.filename {
                matches = records.flatMap { record in
                    record.message.attachments.compactMap { attachment in
                        attachment.filename == expectedFilename
                            ? MediaMatch(record: record, attachment: attachment)
                            : nil
                    }
                }
            } else {
                matches = []
            }
            if matches.count > 1 {
                let narrowed = matches.filter { match in
                    let mimeMatches = expected.mimeType == nil
                        || match.attachment.mimeType == expected.mimeType
                    let sizeMatches = expected.byteSize == nil
                        || match.attachment.byteSize == expected.byteSize
                    return mimeMatches && sizeMatches
                }
                if !narrowed.isEmpty { matches = narrowed }
            }
            if matches.isEmpty,
               let fallbackRecord,
               fallbackAttachments.count == expectedMedia.count {
                let attachment = fallbackAttachments[index]
                let mimeMatches = expected.mimeType == nil
                    || attachment.mimeType == expected.mimeType
                if mimeMatches {
                    matches = [MediaMatch(record: fallbackRecord, attachment: attachment)]
                }
            }
            matches.removeAll { candidate in
                selected.contains { $0.attachment.mediaID == candidate.attachment.mediaID }
            }
            guard matches.count <= 1 else { return nil }
            let match = matches.first
            if let match { selected.append(match) }
            receipts.append(MediaReceipt(
                requestedMediaID: expected.requestedMediaID,
                mediaID: match?.attachment.mediaID,
                messageID: match?.record.message.id
            ))
        }
        let providerMediaIDs = selected.map(\.attachment.mediaID)
        guard Set(providerMediaIDs).count == providerMediaIDs.count else { return nil }
        return (receipts, selected)
    }

    private static func threadMatches(
        _ row: MessageRow,
        criteria: SendCorrelationCriteria
    ) -> Bool {
        guard let reply = criteria.replyToMessageID else {
            return row.threadOriginatorGUID == nil
        }
        return row.replyToGUID == reply.rawValue
            && row.threadOriginatorGUID == criteria.threadOriginatorMessageID?.rawValue
    }

    private static func records(
        database: SQLiteDatabase,
        sql: String,
        query: RecordQuery
    ) throws -> [Record] {
        try database.withStatement(sql) { statement in
            var binding: Int32 = 1
            try statement.bind(query.conversationID.rawValue, at: binding)
            binding += 1
            if let cursor = query.cursor {
                if let date = cursor.date {
                    try date.bind(to: statement, at: binding)
                    try date.bind(to: statement, at: binding + 1)
                    try statement.bind(cursor.rowID, at: binding + 2)
                    binding += 3
                } else {
                    try statement.bind(cursor.rowID, at: binding)
                    binding += 1
                }
            }
            if !query.hasSearch {
                try statement.bind(Int64(query.limit + 1), at: binding)
            }
            var result: [Record] = []
            while try statement.step() == .row {
                let row = try decode(statement)
                let message = try SQLiteRows.message(row)
                result.append(Record(row: row, message: message))
            }
            return result
        }
    }

    private static func coalesceURLPreviews(_ records: [Record]) -> [Record] {
        let previewBundleID = "com.apple.messages.URLBalloonProvider"
        var logical: [Record] = []
        for record in records.reversed() {
            guard record.row.balloonBundleID == previewBundleID,
                  let index = logical.indices.last,
                  logical[index].row.isFromMe == record.row.isFromMe,
                  logical[index].row.handle == record.row.handle,
                  containsURL(logical[index].message.text) else {
                logical.append(record)
                continue
            }
            logical[index].message.urlPreview = URLPreview(
                messageID: record.message.id,
                providerGUID: record.row.guid,
                balloonBundleID: previewBundleID,
                createdAt: record.message.createdAt
            )
        }
        return Array(logical.reversed())
    }

    private static func containsURL(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.localizedCaseInsensitiveContains("https://")
            || text.localizedCaseInsensitiveContains("http://")
    }

    private static func normalizedSearch(_ search: String?) -> String? {
        let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func querySignature(
        conversationID: ConversationID,
        options: MessageListOptions,
        search: String?
    ) -> String {
        CursorCodec.signature([
            "messages",
            conversationID.rawValue,
            String(options.includeAttachments),
            options.searchMode.rawValue,
            search ?? "<none>",
        ])
    }

    private static func listSQL(
        schema: SchemaInspector,
        cursor: StorageCursor?,
        hasSearch: Bool
    ) -> String {
        var sql = """
            SELECT \(projection(schema))
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE c.guid = ?
            """
        if schema.hasColumn("associated_message_type", in: "message") {
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 2000 AND 2006)"
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 3000 AND 3006)"
        }
        if schema.hasColumn("filter_action", in: "chat_message_join") {
            sql += " AND cmj.filter_action = 0"
        }
        if cursor != nil {
            sql += cursor?.date == nil
                ? " AND m.date IS NULL AND m.ROWID < ?"
                : " AND (m.date IS NULL OR m.date < ? OR (m.date = ? AND m.ROWID < ?))"
        }
        sql += " ORDER BY m.date IS NULL, m.date DESC, m.ROWID DESC"
        if !hasSearch { sql += " LIMIT ?" }
        return sql
    }

    private static func record(
        database: SQLiteDatabase,
        messageID: MessageID
    ) throws -> Record? {
        var sql = """
            SELECT \(projection(database.schema))
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            JOIN chat c ON c.ROWID = cmj.chat_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.guid = ?
            """
        if database.schema.hasColumn("associated_message_type", in: "message") {
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 2000 AND 2006)"
            sql += " AND NOT (COALESCE(m.associated_message_type, 0) BETWEEN 3000 AND 3006)"
        }
        if database.schema.hasColumn("filter_action", in: "chat_message_join") {
            sql += " AND cmj.filter_action = 0"
        }
        sql += " LIMIT 1"
        return try database.withStatement(sql) { statement in
            try statement.bind(messageID.rawValue, at: 1)
            guard try statement.step() == .row else { return nil }
            let row = try decode(statement)
            return Record(row: row, message: try SQLiteRows.message(row))
        }
    }

    private static func projection(_ schema: SchemaInspector) -> String {
        let originalHandle = schema.expression(
            "uncanonicalized_id", table: "handle", alias: "h", fallback: "NULL"
        )
        let attributedBody = schema.expression(
            "attributedBody", table: "message", alias: "m", fallback: "NULL"
        )
        let error = schema.expression("error", table: "message", alias: "m", fallback: "NULL")
        let sent = schema.expression("is_sent", table: "message", alias: "m", fallback: "NULL")
        let delivered = schema.expression("is_delivered", table: "message", alias: "m", fallback: "NULL")
        let read = schema.expression("is_read", table: "message", alias: "m", fallback: "NULL")
        let deliveredDate = schema.expression(
            "date_delivered", table: "message", alias: "m", fallback: "NULL"
        )
        let readDate = schema.expression("date_read", table: "message", alias: "m", fallback: "NULL")
        let reply = schema.expression("reply_to_guid", table: "message", alias: "m", fallback: "NULL")
        let root = schema.expression(
            "thread_originator_guid", table: "message", alias: "m", fallback: "NULL"
        )
        let partCount = schema.expression("part_count", table: "message", alias: "m", fallback: "NULL")
        let balloon = schema.expression("balloon_bundle_id", table: "message", alias: "m", fallback: "NULL")
        let audio = schema.expression("is_audio_message", table: "message", alias: "m", fallback: "NULL")
        let scheduleType = schema.expression("schedule_type", table: "message", alias: "m", fallback: "NULL")
        let scheduleState = schema.expression("schedule_state", table: "message", alias: "m", fallback: "NULL")
        let associatedGUID = schema.expression(
            "associated_message_guid", table: "message", alias: "m", fallback: "NULL"
        )
        let associatedType = schema.expression(
            "associated_message_type", table: "message", alias: "m", fallback: "NULL"
        )
        return """
            m.ROWID, m.guid, c.guid, m.text, \(attributedBody), h.id, \(originalHandle),
            m.is_from_me, m.date, \(error), \(sent), \(delivered), \(read),
            \(deliveredDate), \(readDate), \(reply), \(root), \(partCount),
            \(balloon), \(audio), \(scheduleType), \(scheduleState), \(associatedGUID), \(associatedType)
            """
    }

    private static func decode(_ statement: SQLiteStatement) throws -> MessageRow {
        let attributedBody = try SQLiteValue.optionalData(statement, 4)
        return MessageRow(
            rowID: try statement.int64(0),
            guid: try SQLiteValue.text(statement, 1),
            conversationGUID: try SQLiteValue.text(statement, 2),
            text: try SQLiteValue.optionalText(statement, 3),
            decodedBody: DecodedMessageBody(attributedBody),
            handle: try SQLiteValue.optionalText(statement, 5),
            originalHandle: try SQLiteValue.optionalText(statement, 6),
            isFromMe: try statement.int64(7) != 0,
            date: try SQLiteNumber.read(statement, 8),
            error: try SQLiteValue.optionalInt64(statement, 9),
            isSent: try SQLiteRows.bool(statement, 10),
            isDelivered: try SQLiteRows.bool(statement, 11),
            isRead: try SQLiteRows.bool(statement, 12),
            dateDelivered: try SQLiteNumber.read(statement, 13),
            dateRead: try SQLiteNumber.read(statement, 14),
            replyToGUID: try SQLiteValue.optionalText(statement, 15),
            threadOriginatorGUID: try SQLiteValue.optionalText(statement, 16),
            partCount: try SQLiteValue.optionalInt64(statement, 17),
            balloonBundleID: try SQLiteValue.optionalText(statement, 18),
            isAudioMessage: try SQLiteRows.bool(statement, 19),
            scheduleType: try SQLiteValue.optionalInt64(statement, 20),
            scheduleState: try SQLiteValue.optionalInt64(statement, 21),
            associatedMessageGUID: try SQLiteValue.optionalText(statement, 22),
            associatedMessageType: try SQLiteValue.optionalInt64(statement, 23)
        )
    }

    private static func conversationExists(database: SQLiteDatabase, id: ConversationID) throws -> Bool {
        try database.withStatement("SELECT 1 FROM chat WHERE guid = ? LIMIT 1") { statement in
            try statement.bind(id.rawValue, at: 1)
            return try statement.step() == .row
        }
    }

    private static func matches(
        _ text: String?,
        search: String?,
        mode: MessageSearchMode
    ) -> Bool {
        guard let search else { return true }
        guard let text else { return false }
        let locale = Locale(identifier: "en_US_POSIX")
        let foldedText = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        let foldedSearch = search.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        switch mode {
        case .contains: return foldedText.contains(foldedSearch)
        case .exact: return foldedText == foldedSearch
        }
    }

    private static func hydrate(
        database: SQLiteDatabase,
        records: inout [Record],
        attachments: Bool,
        reactions: Bool
    ) throws {
        guard !records.isEmpty else { return }
        if attachments {
            let values = try attachmentReferences(
                database: database,
                messageRowIDs: records.map(\.row.rowID)
            )
            for index in records.indices {
                let attachmentRecords = values[records[index].row.rowID] ?? []
                records[index].message.attachments = attachmentRecords.map(\.reference)
                records[index].message.parts = SQLiteRows.messageParts(
                    records[index].row,
                    attachmentsByGUID: Dictionary(
                        uniqueKeysWithValues: attachmentRecords.map { ($0.guid, $0.reference) }
                    ),
                    attachmentsLoaded: true
                )
            }
        }
        if reactions {
            let values = try reactionReferences(
                database: database,
                targetGUIDs: records.map(\.row.guid)
            )
            for index in records.indices {
                records[index].message.reactions = values[records[index].row.guid] ?? []
            }
        }
    }

    private static func hydrate(
        database: SQLiteDatabase,
        records record: inout Record,
        attachments: Bool,
        reactions: Bool
    ) throws {
        var records = [record]
        try hydrate(database: database, records: &records, attachments: attachments, reactions: reactions)
        record = records[0]
    }

    private static func attachmentReferences(
        database: SQLiteDatabase,
        messageRowIDs: [Int64]
    ) throws -> [Int64: [AttachmentRecord]] {
        let schema = database.schema
        let transferName = schema.expression("transfer_name", table: "attachment", alias: "a", fallback: "NULL")
        let mime = schema.expression("mime_type", table: "attachment", alias: "a", fallback: "NULL")
        let size = schema.expression("total_bytes", table: "attachment", alias: "a", fallback: "NULL")
        let sticker = schema.expression("is_sticker", table: "attachment", alias: "a", fallback: "0")
        let placeholders = messageRowIDs.map { _ in "?" }.joined(separator: ",")
        return try database.withStatement("""
            SELECT maj.message_id, a.guid, \(transferName), \(mime), \(size), \(sticker)
            FROM message_attachment_join maj
            JOIN attachment a ON a.ROWID = maj.attachment_id
            WHERE maj.message_id IN (\(placeholders))
            ORDER BY maj.message_id, a.ROWID
            """) { statement in
                for (index, rowID) in messageRowIDs.enumerated() {
                    try statement.bind(rowID, at: Int32(index + 1))
                }
                var result: [Int64: [AttachmentRecord]] = [:]
                while try statement.step() == .row {
                    let messageRowID = try statement.int64(0)
                    let guid = try SQLiteValue.text(statement, 1)
                    result[messageRowID, default: []].append(AttachmentRecord(
                        guid: guid,
                        reference: MediaReference(
                            mediaID: try MediaID(validating: guid),
                            filename: try SQLiteValue.optionalText(statement, 2),
                            mimeType: try SQLiteValue.optionalText(statement, 3),
                            byteSize: try SQLiteValue.optionalInt64(statement, 4),
                            source: .messages,
                            isSticker: try SQLiteRows.bool(statement, 5) ?? false
                        )
                    ))
                }
                return result
            }
    }

    private static func reactionReferences(
        database: SQLiteDatabase,
        targetGUIDs: [String]
    ) throws -> [String: [Reaction]] {
        let schema = database.schema
        guard schema.hasColumn("associated_message_guid", in: "message"),
              schema.hasColumn("associated_message_type", in: "message") else { return [:] }
        let emoji = schema.expression(
            "associated_message_emoji", table: "message", alias: "r", fallback: "NULL"
        )
        let originalHandle = schema.expression(
            "uncanonicalized_id", table: "handle", alias: "h", fallback: "NULL"
        )
        let normalizedTarget = """
            CASE
              WHEN r.associated_message_guid LIKE 'p:%/%'
                THEN substr(r.associated_message_guid, instr(r.associated_message_guid, '/') + 1)
              WHEN r.associated_message_guid LIKE 'bp:%'
                THEN substr(r.associated_message_guid, 4)
              ELSE r.associated_message_guid
            END
            """
        let placeholders = targetGUIDs.map { _ in "?" }.joined(separator: ",")
        return try database.withStatement("""
            SELECT r.guid, r.associated_message_guid, \(normalizedTarget),
                   r.associated_message_type, \(emoji),
                   h.id, \(originalHandle), r.is_from_me, r.date
            FROM message r
            LEFT JOIN handle h ON h.ROWID = r.handle_id
            WHERE ((r.associated_message_type BETWEEN 2000 AND 2006)
                OR (r.associated_message_type BETWEEN 3000 AND 3006))
              AND \(normalizedTarget) IN (\(placeholders))
            ORDER BY r.date, r.ROWID
            """) { statement in
                for (index, guid) in targetGUIDs.enumerated() {
                    try statement.bind(guid, at: Int32(index + 1))
                }
                var result: [String: [Reaction]] = [:]
                while try statement.step() == .row {
                    let eventGUID = try SQLiteValue.text(statement, 0)
                    let associatedGUID = try SQLiteValue.optionalText(statement, 1)
                    guard let targetGUID = try SQLiteValue.optionalText(statement, 2) else { continue }
                    let rawType = try statement.int64(3)
                    let decoded = reactionType(rawType)
                    result[targetGUID, default: []].append(Reaction(
                        id: try MessageID(validating: eventGUID),
                        targetPartIndex: reactionPartIndex(associatedGUID),
                        kind: decoded.kind,
                        emoji: try SQLiteValue.optionalText(statement, 4),
                        action: decoded.action,
                        sender: SQLiteRows.handle(
                            value: try SQLiteValue.optionalText(statement, 5),
                            original: try SQLiteValue.optionalText(statement, 6)
                        ),
                        isFromMe: try statement.int64(7) != 0,
                        createdAt: SQLiteRows.timestamp(try SQLiteNumber.read(statement, 8))
                    ))
                }
                return result
            }
    }

    private static func reactionPartIndex(_ associatedGUID: String?) -> Int? {
        guard let associatedGUID, associatedGUID.hasPrefix("p:"),
              let slash = associatedGUID.firstIndex(of: "/") else { return nil }
        return Int(associatedGUID[associatedGUID.index(associatedGUID.startIndex, offsetBy: 2)..<slash])
    }

    private static func reactionType(_ value: Int64) -> (kind: ReactionKind, action: ReactionAction) {
        let action: ReactionAction = value >= 3000 ? .removed : .added
        let base = value >= 3000 ? value - 3000 : value - 2000
        let kinds: [ReactionKind] = [.love, .like, .dislike, .laugh, .emphasis, .question, .custom]
        return (kinds.indices.contains(Int(base)) ? kinds[Int(base)] : .unknown, action)
    }
}
