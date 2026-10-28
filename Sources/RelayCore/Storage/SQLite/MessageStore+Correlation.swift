import Foundation

extension SQLiteMessageStore {
    private struct MediaMatch {
        let record: Record
        let attachment: MediaReference
    }

    static func correlate(
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
}
