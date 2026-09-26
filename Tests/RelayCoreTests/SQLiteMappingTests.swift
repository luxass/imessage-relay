import Darwin
import Foundation
import Testing

@testable import RelayCore

@Test
func attributedAttachmentPlaceholderIsNotExposedAsText() throws {
    let placeholder = try MessageDatabaseFixture.archivedAttributedString(
        NSAttributedString(string: "\u{fffc}")
    )
    let mixed = try MessageDatabaseFixture.archivedAttributedString(
        NSAttributedString(string: "Caption\u{fffc}")
    )

    #expect(DecodedMessageBody(placeholder)?.text == nil)
    #expect(DecodedMessageBody(mixed)?.text == "Caption")
}

@Test
func malformedAttributedBodyDoesNotEscapeAsAnObjectiveCException() async throws {
    let malformed = Data("not a legacy archive".utf8)
    #expect(DecodedMessageBody(malformed) == nil)
    let valid = try MessageDatabaseFixture.archivedAttributedString(
        NSAttributedString(string: "Truncated archive")
    )
    #expect(DecodedMessageBody(Data(valid.prefix(20))) == nil)
    #expect(DecodedMessageBody(Data(valid.dropLast(5))) == nil)

    let fixture = try MessageDatabaseFixture()
    try fixture.setAttributedBody(messageRowID: 100, data: malformed)
    let storage = fixture.makeStorage()
    let message = try #require(try await storage.messages.message(
        id: MessageID(validating: MessageDatabaseFixture.rootMessageID)
    ))

    #expect(message.text == "Root message")
    #expect(message.parts == [.text(index: 0, text: "Root message")])
    try await storage.shutdown()
}

@Test
func conversationsMapStableGUIDsParticipantsUnreadStateAndAccountContext() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()

    let page = try await storage.conversations.listConversations(
        options: ConversationListOptions(limit: 10)
    )
    let group = try #require(page.items.first)
    #expect(group.id.rawValue == MessageDatabaseFixture.groupID)
    #expect(group.providerGUID == MessageDatabaseFixture.groupID)
    #expect(group.displayName == "Fixture group")
    #expect(group.isGroup)
    #expect(group.participants.map(\.value) == ["+15005550006", "friend@example.com"])

    let directID = try ConversationID(validating: MessageDatabaseFixture.oneToOneID)
    let direct = try #require(try await storage.conversations.conversation(id: directID))
    #expect(!direct.isGroup)
    #expect(direct.unreadCount == 1)
    #expect(direct.participants.first?.displayValue == "+1 500 555 0006")

    let sendContext = try #require(try await storage.conversations.sendContext(id: directID))
    #expect(sendContext.accountID == "account-guid-imessage")
    #expect(sendContext.accountLogin == "sender@example.com")
    try await storage.shutdown()
}

@Test
func conversationSendContextRejectsAnUnparseableParticipant() async throws {
    let fixture = try MessageDatabaseFixture()
    try fixture.execute("""
        INSERT INTO handle (ROWID, id, service) VALUES (12, '', 'iMessage');
        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (2, 12);
        """)
    let storage = fixture.makeStorage()
    let groupID = try ConversationID(validating: MessageDatabaseFixture.groupID)

    let readable = try #require(try await storage.conversations.conversation(id: groupID))
    #expect(readable.participants.count == 2)
    await #expect(throws: SQLiteStorageError.self) {
        try await storage.conversations.sendContext(id: groupID)
    }
    await #expect(throws: SQLiteStorageError.self) {
        try await storage.conversations.sendContexts(matchingExactParticipants: [
            RecipientHandle.direct(value: "+15005550006"),
            RecipientHandle.direct(value: "friend@example.com"),
        ])
    }
    try await storage.shutdown()
}

@Test
func conversationsFilterByNormalizedParticipant() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()

    let phone = try await storage.conversations.listConversations(
        options: ConversationListOptions(
            limit: 10,
            participant: RecipientHandle.direct(value: "+1 500 555 0006")
        )
    )
    #expect(phone.items.map(\.id.rawValue) == [
        MessageDatabaseFixture.groupID,
        MessageDatabaseFixture.oneToOneID,
    ])

    let email = try await storage.conversations.listConversations(
        options: ConversationListOptions(
            limit: 10,
            participant: RecipientHandle.direct(value: "FRIEND@EXAMPLE.COM")
        )
    )
    #expect(email.items.map(\.id.rawValue) == [MessageDatabaseFixture.groupID])

    let missing = try await storage.conversations.listConversations(
        options: ConversationListOptions(
            limit: 10,
            participant: RecipientHandle.direct(value: "missing@example.com")
        )
    )
    #expect(missing.items.isEmpty)
    try await storage.shutdown()
}

@Test
func conversationSendContextsRequireAnExactNormalizedParticipantSet() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let participants = [
        try RecipientHandle.direct(value: "+1 500 555 0006"),
        try RecipientHandle.direct(value: "FRIEND@EXAMPLE.COM"),
    ]

    let exact = try await storage.conversations.sendContexts(
        matchingExactParticipants: Array(participants.reversed())
    )
    #expect(exact.map(\.conversationID.rawValue) == [MessageDatabaseFixture.groupID])

    let subset = try await storage.conversations.sendContexts(
        matchingExactParticipants: [participants[0]]
    )
    #expect(subset.map(\.conversationID.rawValue) == [MessageDatabaseFixture.oneToOneID])

    let missing = try await storage.conversations.sendContexts(
        matchingExactParticipants: [
            participants[0],
            try RecipientHandle.direct(value: "missing@example.com"),
        ]
    )
    #expect(missing.isEmpty)

    try fixture.execute("""
        INSERT INTO chat
            (ROWID, guid, chat_identifier, service_name, display_name, room_name,
             account_id, account_login)
        VALUES
            (3, 'iMessage;+;duplicate-group', 'duplicate-group', 'iMessage',
             'Duplicate group', 'duplicate-group', 'account-guid-imessage',
             'sender@example.com');
        INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (3, 10), (3, 11);
        """)
    let ambiguous = try await storage.conversations.sendContexts(
        matchingExactParticipants: participants
    )
    #expect(ambiguous.map(\.conversationID.rawValue) == [
        MessageDatabaseFixture.groupID,
        "iMessage;+;duplicate-group",
    ])
    try await storage.shutdown()
}

@Test
func messagesMapAttributedTextThreadsReactionsAttachmentsAndReceipts() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()

    let nested = try #require(try await storage.messages.message(
        id: MessageID(validating: MessageDatabaseFixture.nestedReplyID)
    ))
    #expect(nested.thread?.replyToMessageID == nil)
    #expect(nested.thread?.providerReplyToMessageID?.rawValue == MessageDatabaseFixture.immediateReplyID)
    #expect(nested.thread?.threadOriginatorMessageID?.rawValue == MessageDatabaseFixture.rootMessageID)
    #expect(nested.isFromMe)
    #expect(nested.deliveryState == .sent)

    let root = try #require(try await storage.messages.message(
        id: MessageID(validating: MessageDatabaseFixture.rootMessageID)
    ))
    #expect(root.sender?.type == .phone)
    #expect(root.readState == .unread)
    #expect(root.reactions.map(\.kind) == [.love, .custom])
    #expect(root.reactions.map(\.targetPartIndex) == [0, nil])
    #expect(root.reactions.last?.emoji == "🎉")
    #expect(try await storage.messages.message(
        id: MessageID(validating: "00000000-0000-0000-0000-000000000105")
    ) == nil)

    let attributed = try #require(try await storage.messages.message(
        id: MessageID(validating: "00000000-0000-0000-0000-000000000102")
    ))
    #expect(attributed.text == "Attributed fixture text")
    #expect(attributed.attachments.first?.mediaID.rawValue == MessageDatabaseFixture.attachmentID)
    #expect(attributed.attachments.first?.filename == "photo.jpg")
    #expect(attributed.attachments.first?.mimeType == "image/jpeg")
    #expect(attributed.parts == [
        .attachment(index: 0, attachment: attributed.attachments.first),
        .text(index: 1, text: "Attributed fixture text"),
    ])

    let outgoing = try #require(try await storage.messages.message(
        id: MessageID(validating: "00000000-0000-0000-0000-000000000101")
    ))
    #expect(outgoing.deliveryState == .delivered)
    #expect(outgoing.readState == .read)
    #expect(outgoing.deliveredAt != nil)
    #expect(outgoing.readAt != nil)
    #expect(outgoing.thread == nil)

    try await storage.shutdown()
}

@Test
func messagesDecodePreviewsPollsSchedulesAudioAndStickers() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let textID = "00000000-0000-0000-0000-000000000110"
    let previewID = "00000000-0000-0000-0000-000000000111"
    let pollID = "00000000-0000-0000-0000-000000000112"
    let voteID = "00000000-0000-0000-0000-000000000113"
    let scheduledID = "00000000-0000-0000-0000-000000000114"
    try fixture.execute("""
        UPDATE attachment SET is_sticker = 1
        WHERE guid = '\(MessageDatabaseFixture.attachmentID)';
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, balloon_bundle_id,
             is_audio_message, schedule_type, schedule_state,
             associated_message_guid, associated_message_type)
        VALUES
            (110, '\(textID)', 'Read https://example.com', 10, 0,
             700000310000000000, NULL, 0, 0, 0, NULL, 0),
            (111, '\(previewID)', NULL, 10, 0,
             700000311000000000, 'com.apple.messages.URLBalloonProvider', 0, 0, 0, NULL, 0),
            (112, '\(pollID)', NULL, 10, 0,
             700000312000000000, 'com.apple.messages.Polls', 0, 0, 0, NULL, 0),
            (113, '\(voteID)', NULL, 10, 0,
             700000313000000000, NULL, 0, 0, 0, 'p:0/\(pollID)', 4000),
            (114, '\(scheduledID)', 'Later', NULL, 1,
             900000000000000000, NULL, 1, 2, 1, NULL, 0);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES
            (1, 110, 700000310000000000, 0),
            (1, 111, 700000311000000000, 0),
            (1, 112, 700000312000000000, 0),
            (1, 113, 700000313000000000, 0),
            (1, 114, 900000000000000000, 0);
        """)

    let page = try await storage.messages.listMessages(
        conversationID: ConversationID(validating: MessageDatabaseFixture.oneToOneID),
        options: MessageListOptions(limit: 20, includeAttachments: true)
    )
    let link = try #require(page.items.first { $0.id.rawValue == textID })
    #expect(page.items.contains { $0.id.rawValue == previewID } == false)
    #expect(link.urlPreview?.messageID.rawValue == previewID)
    #expect(link.urlPreview?.balloonBundleID == "com.apple.messages.URLBalloonProvider")
    #expect(page.items.first { $0.id.rawValue == pollID }?.poll?.kind == .created)
    #expect(page.items.first { $0.id.rawValue == voteID }?.poll?.kind == .vote)
    #expect(page.items.first { $0.id.rawValue == voteID }?.poll?.originalMessageID?.rawValue == pollID)
    let scheduled = try #require(page.items.first { $0.id.rawValue == scheduledID })
    #expect(scheduled.isAudioMessage == true)
    #expect(scheduled.schedule?.type == 2)
    #expect(scheduled.schedule?.state == 1)
    #expect(page.items.flatMap(\.attachments).first?.isSticker == true)
    let search = try await storage.messages.listMessages(
        conversationID: ConversationID(validating: MessageDatabaseFixture.oneToOneID),
        options: MessageListOptions(limit: 20, search: "example.com")
    )
    #expect(search.items.map(\.id.rawValue) == [textID])
    #expect(search.items.first?.urlPreview?.messageID.rawValue == previewID)
    try await storage.shutdown()
}

@Test
func messageListsExcludeReactionEventsAlwaysIncludeReactionsAndHonorAttachmentProjectionAndSearch() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let conversationID = try ConversationID(validating: MessageDatabaseFixture.oneToOneID)

    let withoutRelated = try await storage.messages.listMessages(
        conversationID: conversationID,
        options: MessageListOptions(limit: 20)
    )
    #expect(withoutRelated.items.count == 5)
    #expect(withoutRelated.items.allSatisfy { $0.attachments.isEmpty })
    #expect(withoutRelated.items.first {
        $0.id.rawValue == MessageDatabaseFixture.rootMessageID
    }?.reactions.count == 2)
    let structured = try #require(withoutRelated.items.first { $0.text == "Attributed fixture text" })
    #expect(structured.parts == [
        .attachment(index: 0, attachment: nil),
        .text(index: 1, text: "Attributed fixture text"),
    ])

    let searched = try await storage.messages.listMessages(
        conversationID: conversationID,
        options: MessageListOptions(limit: 20, search: "attributed FIXTURE", searchMode: .contains)
    )
    #expect(searched.items.map(\.text) == ["Attributed fixture text"])

    let included = try await storage.messages.listMessages(
        conversationID: conversationID,
        options: MessageListOptions(limit: 20, includeAttachments: true)
    )
    #expect(included.items.first { $0.id.rawValue == MessageDatabaseFixture.rootMessageID }?.reactions.count == 2)
    #expect(included.items.first { $0.text == "Attributed fixture text" }?.attachments.count == 1)
    try await storage.shutdown()
}

@Test
func boundedSearchReturnsAdvancingEmptyContinuationPagesWithoutSkippingMatches() async throws {
    let fixture = try MessageDatabaseFixture()
    try insertSearchHistory(into: fixture, count: 600) { index in
        (index == 0 || index == 100) ? "Needle \(index)" : "Haystack \(index)"
    }
    let storage = fixture.makeStorage()
    let conversationID = try ConversationID(validating: MessageDatabaseFixture.oneToOneID)
    var cursor: Cursor?
    var pages = 0
    var matched: [String] = []
    var sawEmptyContinuation = false
    repeat {
        let page = try await storage.messages.listMessages(
            conversationID: conversationID,
            options: MessageListOptions(limit: 1, cursor: cursor, search: "needle")
        )
        pages += 1
        if page.items.isEmpty && page.hasMore {
            sawEmptyContinuation = true
            #expect(page.nextCursor != nil)
        }
        matched.append(contentsOf: page.items.map(\.id.rawValue))
        if page.hasMore {
            let next = try #require(page.nextCursor)
            #expect(next != cursor)
            cursor = next
        } else {
            cursor = nil
        }
        #expect(pages < 10)
    } while cursor != nil

    #expect(sawEmptyContinuation)
    #expect(matched == ["search-history-100", "search-history-0"])
    #expect(Set(matched).count == matched.count)
    try await storage.shutdown()
}

@Test
func boundedSearchCarriesURLPreviewOverlapAcrossCandidatePages() async throws {
    let fixture = try MessageDatabaseFixture()
    try insertSearchHistory(into: fixture, count: 400) { index in
        index == 143 ? "Boundary https://example.com" : "Haystack \(index)"
    }
    try fixture.execute("""
        UPDATE message
        SET text = NULL, balloon_bundle_id = 'com.apple.messages.URLBalloonProvider'
        WHERE guid = 'search-history-144'
        """)
    let storage = fixture.makeStorage()
    let conversationID = try ConversationID(validating: MessageDatabaseFixture.oneToOneID)

    let first = try await storage.messages.listMessages(
        conversationID: conversationID,
        options: MessageListOptions(limit: 1, search: "boundary")
    )
    let firstCursor = try #require(first.nextCursor)
    #expect(first.items.isEmpty)
    #expect(first.hasMore)
    var cursor: Cursor? = firstCursor
    var match: Message?
    var continuations = 0
    while let current = cursor, match == nil {
        let page = try await storage.messages.listMessages(
            conversationID: conversationID,
            options: MessageListOptions(
                limit: 1,
                cursor: current,
                search: "boundary"
            )
        )
        match = page.items.first
        cursor = page.hasMore ? page.nextCursor : nil
        continuations += 1
        #expect(continuations < 5)
    }
    let resolvedMatch = try #require(match)
    #expect(resolvedMatch.id.rawValue == "search-history-143")
    #expect(resolvedMatch.urlPreview?.messageID.rawValue == "search-history-144")
    try await storage.shutdown()
}

@Test
func cursorsAreOpaqueStableAndBoundToTheirQuery() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()

    let first = try await storage.conversations.listConversations(
        options: ConversationListOptions(limit: 1)
    )
    let cursor = try #require(first.nextCursor)
    #expect(!cursor.rawValue.contains(MessageDatabaseFixture.groupID))

    let second = try await storage.conversations.listConversations(
        options: ConversationListOptions(limit: 1, cursor: cursor)
    )
    #expect(second.items.map(\.id.rawValue) == [MessageDatabaseFixture.oneToOneID])

    await #expect(throws: SQLiteStorageError.invalidCursor) {
        try await storage.conversations.listConversations(
            options: ConversationListOptions(limit: 1, cursor: cursor, unreadOnly: true)
        )
    }

    let participantPage = try await storage.conversations.listConversations(
        options: ConversationListOptions(
            limit: 1,
            participant: RecipientHandle.direct(value: "+15005550006")
        )
    )
    let participantCursor = try #require(participantPage.nextCursor)
    await #expect(throws: SQLiteStorageError.invalidCursor) {
        try await storage.conversations.listConversations(
            options: ConversationListOptions(limit: 1, cursor: participantCursor)
        )
    }
    try await storage.shutdown()
}

@Test
func supportedSchemaWithoutOptionalColumnsMapsUnknownsInsteadOfInventingValues() async throws {
    let fixture = try MessageDatabaseFixture(options: .init(
        includeOptionalMessageColumns: false,
        includeOptionalChatColumns: false,
        includeOptionalAttachmentColumns: false
    ))
    let storage = fixture.makeStorage()

    let message = try #require(try await storage.messages.message(
        id: MessageID(validating: MessageDatabaseFixture.rootMessageID)
    ))
    #expect(message.text == nil)
    #expect(message.createdAt == nil)
    #expect(message.deliveryState == .unknown)
    #expect(message.readState == .unknown)
    #expect(message.thread == nil)
    #expect(message.parts == nil)
    #expect(message.attachments.isEmpty)
    #expect(message.reactions.isEmpty)
    try await storage.shutdown()
}

@Test
func providerMediaOpensOnlyLinkedRegularFilesWithinTheAttachmentRoot() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let media = try #require(try await storage.media.media(
        id: MediaID(validating: MessageDatabaseFixture.attachmentID)
    ))

    #expect(media.reference.filename == "photo.jpg")
    #expect(String(data: try media.readChunk(offset: 0), encoding: .utf8) == "fixture attachment")

    let file = fixture.attachmentDirectory
        .appendingPathComponent("fixture", isDirectory: true)
        .appendingPathComponent("photo.jpg")
    let hardLink = fixture.attachmentDirectory.appendingPathComponent("linked-photo.jpg")
    try FileManager.default.linkItem(at: file, to: hardLink)
    #expect(try await storage.media.media(
        id: MediaID(validating: MessageDatabaseFixture.attachmentID)
    ) == nil)
    try FileManager.default.removeItem(at: hardLink)

    let alias = fixture.attachmentDirectory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(
        at: alias,
        withDestinationURL: file.deletingLastPathComponent()
    )
    try fixture.execute("""
        UPDATE attachment SET filename = '\(alias.appendingPathComponent("photo.jpg").path)'
        WHERE guid = '\(MessageDatabaseFixture.attachmentID)'
        """)
    #expect(try await storage.media.media(
        id: MediaID(validating: MessageDatabaseFixture.attachmentID)
    ) == nil)

    let pipe = fixture.attachmentDirectory.appendingPathComponent("attachment.pipe")
    #expect(mkfifo(pipe.path, 0o600) == 0)
    try fixture.execute("""
        UPDATE attachment SET filename = '\(pipe.path)'
        WHERE guid = '\(MessageDatabaseFixture.attachmentID)'
        """)
    #expect(try await storage.media.media(
        id: MediaID(validating: MessageDatabaseFixture.attachmentID)
    ) == nil)

    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("changed".utf8))
    try handle.close()
    #expect(throws: SQLiteStorageError.self) {
        try media.readChunk(offset: 0)
    }

    try fixture.execute("""
        UPDATE attachment SET filename = '/etc/passwd'
        WHERE guid = '\(MessageDatabaseFixture.attachmentID)'
        """)
    #expect(try await storage.media.media(
        id: MediaID(validating: MessageDatabaseFixture.attachmentID)
    ) == nil)
    try await storage.shutdown()
}

@Test
func sendCorrelationUsesThePreSendRowIDAndStableConversationID() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let checkpoint = try await storage.messages.checkpoint()
    let messageID = "00000000-0000-0000-0000-000000000300"
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, error, is_sent,
             is_delivered, is_read, date_delivered, date_read, reply_to_guid,
             thread_originator_guid, associated_message_type)
        VALUES
            (300, '\(messageID)', 'Correlated outgoing text', NULL, 1,
             700000500000000000, 0, 1, 1, 0, 700000501000000000, 0, NULL, NULL, 0);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES (1, 300, 700000500000000000, 0);
        """)
    let criteria = SendCorrelationCriteria(
        checkpoint: checkpoint,
        destination: .conversation(try ConversationID(validating: MessageDatabaseFixture.oneToOneID)),
        text: "Correlated outgoing text",
        media: [],
        replyToMessageID: nil,
        threadOriginatorMessageID: nil,
        accountID: "account-guid-imessage"
    )

    let outcome = try await storage.messages.correlate(criteria)

    guard case .complete(let snapshot) = outcome,
          let message = snapshot.messages.first else {
        Issue.record("Expected one correlated provider message, got \(outcome)")
        try await storage.shutdown()
        return
    }
    #expect(message.id.rawValue == messageID)
    #expect(message.deliveryState == .delivered)
    try await storage.shutdown()
}

@Test
func sendCorrelationFindsANewGroupByItsExactParticipantSet() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let checkpoint = try await storage.messages.checkpoint()
    let messageID = "00000000-0000-0000-0000-000000000305"
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, error, is_sent,
             is_delivered, is_read, associated_message_type)
        VALUES
            (305, '\(messageID)', 'New group text', NULL, 1,
             700000505000000000, 0, 1, 0, 0, 0);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES (2, 305, 700000505000000000, 0);
        """)
    let criteria = SendCorrelationCriteria(
        checkpoint: checkpoint,
        destination: .participants([
            try RecipientHandle.direct(value: "FRIEND@EXAMPLE.COM"),
            try RecipientHandle.direct(value: "+1 500 555 0006"),
        ]),
        text: "New group text",
        media: [],
        replyToMessageID: nil,
        threadOriginatorMessageID: nil,
        accountID: "account-guid-imessage"
    )

    let outcome = try await storage.messages.correlate(criteria)

    guard case .complete(let snapshot) = outcome else {
        Issue.record("Expected a complete group correlation, got \(outcome)")
        try await storage.shutdown()
        return
    }
    #expect(snapshot.messages.map(\.id.rawValue) == [messageID])
    #expect(snapshot.messages.first?.conversationID.rawValue == MessageDatabaseFixture.groupID)

    let wrongAccount = SendCorrelationCriteria(
        checkpoint: checkpoint,
        destination: criteria.destination,
        text: criteria.text,
        media: [],
        replyToMessageID: nil,
        threadOriginatorMessageID: nil,
        accountID: "another-account"
    )
    #expect(try await storage.messages.correlate(wrongAccount) == .pending)
    try await storage.shutdown()
}

@Test
func sendCorrelationFindsAMediaOnlyMessageWhenMessagesRenamesTheFile() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let checkpoint = try await storage.messages.checkpoint()
    let messageID = "00000000-0000-0000-0000-000000000301"
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, error, is_sent,
             is_delivered, is_read, associated_message_type)
        VALUES
            (301, '\(messageID)', NULL, NULL, 1, 700000510000000000, 0, 1, 0, 0, 0);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES (1, 301, 700000510000000000, 0);
        INSERT INTO attachment
            (ROWID, guid, original_guid, filename, transfer_name, mime_type, uti, total_bytes)
        VALUES
            (302, '00000000-0000-0000-0000-000000000302', 'uploaded-original-guid',
             '/synthetic/renamed-path.jpg', 'agent-photo.jpg', 'image/jpeg', 'public.jpeg', 99);
        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (301, 302);
        """)
    let criteria = SendCorrelationCriteria(
        checkpoint: checkpoint,
        destination: .recipient(try RecipientHandle(type: .phone, value: "+1 500 555 0006")),
        text: nil,
        media: [SendCorrelationMedia(
            requestedMediaID: try MediaID(validating: "upload_agent_photo"),
            filename: "original-upload-name.jpg",
            mimeType: "image/jpeg",
            byteSize: 42
        )],
        replyToMessageID: nil,
        threadOriginatorMessageID: nil
    )

    let outcome = try await storage.messages.correlate(criteria)

    guard case .complete(let snapshot) = outcome,
          let message = snapshot.messages.first else {
        Issue.record("Expected the media-only provider message, got \(outcome)")
        try await storage.shutdown()
        return
    }
    #expect(message.id.rawValue == messageID)
    #expect(message.attachments.first?.filename == "agent-photo.jpg")
    #expect(snapshot.media.first?.requestedMediaID.rawValue == "upload_agent_photo")
    #expect(snapshot.media.first?.mediaID?.rawValue == "00000000-0000-0000-0000-000000000302")
    #expect(snapshot.media.first?.messageID == message.id)
    try await storage.shutdown()
}

@Test
func sendCorrelationCombinesSplitTextAndAttachmentProviderMessages() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let checkpoint = try await storage.messages.checkpoint()
    let textMessageID = "00000000-0000-0000-0000-000000000310"
    let mediaMessageID = "00000000-0000-0000-0000-000000000311"
    let attachmentID = "00000000-0000-0000-0000-000000000312"
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, error, is_sent,
             is_delivered, is_read, associated_message_type)
        VALUES
            (310, '\(textMessageID)', 'Split send ', NULL, 1,
             700000530000000000, 0, 1, 1, 0, 0),
            (311, '\(mediaMessageID)', NULL, NULL, 1,
             700000530000000001, 0, 1, 1, 0, 0);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES
            (1, 310, 700000530000000000, 0),
            (1, 311, 700000530000000001, 0);
        INSERT INTO attachment
            (ROWID, guid, original_guid, filename, transfer_name, mime_type, uti, total_bytes)
        VALUES
            (312, '\(attachmentID)', 'uploaded-split-guid',
             '/synthetic/messages-path.jpg', 'split-photo.jpg', 'image/jpeg', 'public.jpeg', 123);
        INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (311, 312);
        """)
    let requestedMediaID = try MediaID(validating: "upload_split_photo")
    let criteria = SendCorrelationCriteria(
        checkpoint: checkpoint,
        destination: .conversation(try ConversationID(validating: MessageDatabaseFixture.oneToOneID)),
        text: "Split send",
        media: [SendCorrelationMedia(
            requestedMediaID: requestedMediaID,
            filename: "split-photo.jpg",
            mimeType: "image/jpeg",
            byteSize: 123
        )],
        replyToMessageID: nil,
        threadOriginatorMessageID: nil
    )

    let outcome = try await storage.messages.correlate(criteria)

    guard case .complete(let snapshot) = outcome else {
        Issue.record("Expected a complete split-message correlation, got \(outcome)")
        try await storage.shutdown()
        return
    }
    #expect(snapshot.messages.map(\.id.rawValue) == [textMessageID, mediaMessageID])
    #expect(snapshot.media == [MediaReceipt(
        requestedMediaID: requestedMediaID,
        mediaID: try MediaID(validating: attachmentID),
        messageID: try MessageID(validating: mediaMessageID)
    )])
    try await storage.shutdown()
}

@Test
func sendCorrelationReportsPartialUntilEveryRequestedMediaItemAppears() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let checkpoint = try await storage.messages.checkpoint()
    let textMessageID = "00000000-0000-0000-0000-000000000320"
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, error, is_sent,
             is_delivered, is_read, associated_message_type)
        VALUES
            (320, '\(textMessageID)', 'Waiting for media', NULL, 1,
             700000540000000000, 0, 1, 1, 0, 0);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES (1, 320, 700000540000000000, 0);
        """)
    let requestedMediaID = try MediaID(validating: "upload_waiting_photo")
    let criteria = SendCorrelationCriteria(
        checkpoint: checkpoint,
        destination: .conversation(try ConversationID(validating: MessageDatabaseFixture.oneToOneID)),
        text: "Waiting for media",
        media: [SendCorrelationMedia(
            requestedMediaID: requestedMediaID,
            filename: "waiting-photo.jpg",
            mimeType: "image/jpeg",
            byteSize: 123
        )],
        replyToMessageID: nil,
        threadOriginatorMessageID: nil
    )

    let outcome = try await storage.messages.correlate(criteria)

    guard case .partial(let snapshot) = outcome else {
        Issue.record("Expected a partial correlation, got \(outcome)")
        try await storage.shutdown()
        return
    }
    #expect(snapshot.messages.map(\.id.rawValue) == [textMessageID])
    #expect(snapshot.media == [MediaReceipt(
        requestedMediaID: requestedMediaID,
        mediaID: nil,
        messageID: nil
    )])
    try await storage.shutdown()
}

@Test
func sendCorrelationReportsAReplyRelationshipMismatch() async throws {
    let fixture = try MessageDatabaseFixture()
    let storage = fixture.makeStorage()
    let checkpoint = try await storage.messages.checkpoint()
    let messageID = "00000000-0000-0000-0000-000000000303"
    try fixture.execute("""
        INSERT INTO message
            (ROWID, guid, text, handle_id, is_from_me, date, error, is_sent,
             is_delivered, is_read, reply_to_guid, thread_originator_guid,
             associated_message_type)
        VALUES
            (303, '\(messageID)', 'Reply with wrong parent', NULL, 1,
             700000520000000000, 0, 1, 1, 0,
             'wrong-parent-guid', '\(MessageDatabaseFixture.rootMessageID)', 0);
        INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
        VALUES (1, 303, 700000520000000000, 0);
        """)
    let criteria = SendCorrelationCriteria(
        checkpoint: checkpoint,
        destination: .conversation(try ConversationID(validating: MessageDatabaseFixture.oneToOneID)),
        text: "Reply with wrong parent",
        media: [],
        replyToMessageID: try MessageID(validating: MessageDatabaseFixture.immediateReplyID),
        threadOriginatorMessageID: try MessageID(validating: MessageDatabaseFixture.rootMessageID)
    )

    let outcome = try await storage.messages.correlate(criteria)

    guard case .mismatched = outcome else {
        Issue.record("Expected an explicit reply mismatch, got \(outcome)")
        try await storage.shutdown()
        return
    }
    try await storage.shutdown()
}

private func insertSearchHistory(
    into fixture: MessageDatabaseFixture,
    count: Int,
    text: (Int) -> String
) throws {
    try fixture.execute("BEGIN")
    for start in stride(from: 0, to: count, by: 200) {
        let end = min(start + 200, count)
        let messages = (start..<end).map { index in
            let escaped = text(index).replacingOccurrences(of: "'", with: "''")
            return """
                (\(1_000 + index), 'search-history-\(index)', '\(escaped)', 10, 0,
                 \(800000000000000000 + index), 0)
                """
        }.joined(separator: ",")
        let joins = (start..<end).map { index in
            "(1, \(1_000 + index), \(800000000000000000 + index), 0)"
        }.joined(separator: ",")
        try fixture.execute("""
            INSERT INTO message
                (ROWID, guid, text, handle_id, is_from_me, date, associated_message_type)
            VALUES \(messages);
            INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
            VALUES \(joins)
            """)
    }
    try fixture.execute("COMMIT")
}
