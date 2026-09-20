import Foundation
import Testing

@testable import RelayCore

@Test
func boundedSearchDoesNotSkipPreviewOnlyCandidateWindows() async throws {
    let fixture = try MessageDatabaseFixture()
    try insertPreviewSearchHistory(into: fixture, count: 300)
    let storage = fixture.makeStorage()
    let conversationID = try ConversationID(validating: MessageDatabaseFixture.oneToOneID)
    var cursor: Cursor?
    var matched: [String] = []
    var pages = 0

    repeat {
        let page = try await storage.messages.listMessages(
            conversationID: conversationID,
            options: MessageListOptions(limit: 32, cursor: cursor, search: "needle")
        )
        matched.append(contentsOf: page.items.map(\.id.rawValue))
        pages += 1
        if page.hasMore {
            let next = try #require(page.nextCursor)
            #expect(next != cursor)
            cursor = next
        } else {
            cursor = nil
        }
        #expect(pages < 20)
    } while cursor != nil

    #expect(matched.count == 300)
    #expect(Set(matched).count == 300)
    try await storage.shutdown()
}

@Test
func boundedSearchPreservesMultiPreviewGroupsAcrossPageSizes() async throws {
    let fixture = try MessageDatabaseFixture()
    try insertPreviewBoundaryHistory(into: fixture, count: 300)
    let storage = fixture.makeStorage()
    let conversationID = try ConversationID(validating: MessageDatabaseFixture.oneToOneID)

    let large = try await storage.messages.listMessages(
        conversationID: conversationID,
        options: MessageListOptions(limit: 200, search: "boundary")
    )
    var cursor: Cursor?
    var small: [Message] = []
    var pages = 0
    repeat {
        let page = try await storage.messages.listMessages(
            conversationID: conversationID,
            options: MessageListOptions(limit: 1, cursor: cursor, search: "boundary")
        )
        small.append(contentsOf: page.items)
        pages += 1
        cursor = page.hasMore ? page.nextCursor : nil
        #expect(!page.hasMore || cursor != nil)
        #expect(pages < 10)
    } while cursor != nil

    #expect(small.map(\.id) == large.items.map(\.id))
    #expect(small.map(\.urlPreview) == large.items.map(\.urlPreview))
    #expect(small.map(\.id.rawValue) == ["preview-boundary-43"])
    #expect(small.first?.urlPreview?.messageID.rawValue == "preview-boundary-45")
    try await storage.shutdown()
}

enum PreviewBoundaryScenario: CaseIterable, Sendable {
    case mixedSenders
    case previewContainingURL
}

@Test(arguments: PreviewBoundaryScenario.allCases)
func boundedSearchUsesTheSamePreviewRulesAcrossContinuations(
    scenario: PreviewBoundaryScenario
) async throws {
    let fixture = try MessageDatabaseFixture()
    try insertPreviewBoundaryHistory(into: fixture, count: 300)
    try fixture.execute("""
        UPDATE message SET text = 'Boundary preview'
        WHERE guid IN ('preview-boundary-44', 'preview-boundary-45');
        UPDATE message SET text = 'Boundary before' WHERE guid = 'preview-boundary-299';
        UPDATE message SET text = 'Boundary after' WHERE guid = 'preview-boundary-0';
        """)
    let expectedGroup: [Int]
    let expectedPreview: String?
    switch scenario {
    case .mixedSenders:
        try fixture.execute("UPDATE message SET is_from_me = 1 WHERE guid = 'preview-boundary-44'")
        expectedGroup = [45, 44, 43]
        expectedPreview = nil
    case .previewContainingURL:
        try fixture.execute("""
            UPDATE message SET text = 'Boundary base' WHERE guid = 'preview-boundary-43';
            UPDATE message SET text = 'Boundary https://example.com' WHERE guid = 'preview-boundary-44';
            """)
        expectedGroup = [44, 43]
        expectedPreview = "preview-boundary-45"
    }
    let storage = fixture.makeStorage()
    let large = try await collectPreviewSearch(storage, limit: 200)
    let small = try await collectPreviewSearch(storage, limit: 1)
    let expectedIDs = ([299] + expectedGroup + [0]).map { "preview-boundary-\($0)" }
    #expect(large.map(\.id.rawValue) == expectedIDs)
    #expect(small.map(\.id) == large.map(\.id))
    #expect(small.map(\.urlPreview) == large.map(\.urlPreview))
    #expect(small.compactMap { $0.urlPreview?.messageID.rawValue } == expectedPreview.map { [$0] } ?? [])
    try await storage.shutdown()
}

@Test
func boundedSearchResolvesPreviewRunsLongerThanItsCandidateBudget() async throws {
    let fixture = try MessageDatabaseFixture()
    try insertPreviewSearchHistory(into: fixture, count: 900)
    try fixture.execute("""
        UPDATE message SET text = 'Needle https://example.com'
        WHERE guid IN ('preview-search-100', 'preview-search-600');
        """)
    let storage = fixture.makeStorage()
    let large = try await collectPreviewSearch(storage, limit: 200, search: "needle")
    let small = try await collectPreviewSearch(storage, limit: 32, search: "needle")
    #expect(large.map(\.id.rawValue) == (0...100).reversed().map { "preview-search-\($0)" })
    #expect(small.map(\.id) == large.map(\.id))
    #expect(small.map(\.urlPreview) == large.map(\.urlPreview))
    #expect(small.first?.urlPreview?.messageID.rawValue == "preview-search-899")
    #expect(small.dropFirst().allSatisfy { $0.urlPreview == nil })
    try await storage.shutdown()
}

private func collectPreviewSearch(
    _ storage: MessagesStorage,
    limit: Int,
    search: String = "boundary"
) async throws -> [Message] {
    let conversationID = try ConversationID(validating: MessageDatabaseFixture.oneToOneID)
    var cursor: Cursor?
    var seen: Set<String> = []
    var result: [Message] = []
    for _ in 0..<100 {
        let page = try await storage.messages.listMessages(
            conversationID: conversationID,
            options: MessageListOptions(limit: limit, cursor: cursor, search: search)
        )
        result.append(contentsOf: page.items)
        if !page.hasMore { return result }
        let next = try #require(page.nextCursor)
        try #require(seen.insert(next.rawValue).inserted, "A continuation must make progress.")
        cursor = next
    }
    Issue.record("Search did not finish within the bounded fixture's page allowance.")
    return result
}

private func insertPreviewSearchHistory(
    into fixture: MessageDatabaseFixture,
    count: Int
) throws {
    try fixture.execute("BEGIN")
    for start in stride(from: 0, to: count, by: 200) {
        let end = min(start + 200, count)
        let messages = (start..<end).map { index in
            """
                (\(1_000 + index), 'preview-search-\(index)', 'Needle \(index)', 10, 0,
                 \(800000000000000000 + index), 0, 'com.apple.messages.URLBalloonProvider')
                """
        }.joined(separator: ",")
        let joins = (start..<end).map { index in
            "(1, \(1_000 + index), \(800000000000000000 + index), 0)"
        }.joined(separator: ",")
        try fixture.execute("""
            INSERT INTO message
                (ROWID, guid, text, handle_id, is_from_me, date,
                 associated_message_type, balloon_bundle_id)
            VALUES \(messages);
            INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
            VALUES \(joins)
            """)
    }
    try fixture.execute("COMMIT")
}

private func insertPreviewBoundaryHistory(
    into fixture: MessageDatabaseFixture,
    count: Int
) throws {
    try fixture.execute("BEGIN")
    for start in stride(from: 0, to: count, by: 200) {
        let end = min(start + 200, count)
        let messages = (start..<end).map { index -> String in
            let text = index == 43 ? "'Boundary https://example.com'" : "'Haystack \(index)'"
            let bundle = (index == 44 || index == 45)
                ? "'com.apple.messages.URLBalloonProvider'"
                : "NULL"
            return """
                (\(2_000 + index), 'preview-boundary-\(index)', \(text), 10, 0,
                 \(810000000000000000 + index), 0, \(bundle))
                """
        }.joined(separator: ",")
        let joins = (start..<end).map { index in
            "(1, \(2_000 + index), \(810000000000000000 + index), 0)"
        }.joined(separator: ",")
        try fixture.execute("""
            INSERT INTO message
                (ROWID, guid, text, handle_id, is_from_me, date,
                 associated_message_type, balloon_bundle_id)
            VALUES \(messages);
            INSERT INTO chat_message_join (chat_id, message_id, message_date, filter_action)
            VALUES \(joins)
            """)
    }
    try fixture.execute("COMMIT")
}
