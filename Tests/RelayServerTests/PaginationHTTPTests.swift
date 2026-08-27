import Foundation
import HTTPTypes
import HummingbirdTesting
import NIOCore
import Testing

@testable import relay_server

@Test("canonical routes traverse synthetic chats and per-chat history")
func traversal() async throws {
    let fixture = try ServerDatabaseFixture()
    try fixture.execute(
        """
        INSERT INTO message (ROWID, guid, text, is_from_me, is_read, date)
        VALUES (101, 'guid-101', 'hello fixture second', 0, 1, 700000000);
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 101);
        """)
    let app = makeTestApplication(databasePath: fixture.path)

    try await app.test(.router) { client in
        let firstChats = try await client.execute(uri: "/chats?limit=1", method: .get)
        #expect(firstChats.status == .ok)
        let firstChatPage = try pageJSONObject(firstChats.body)
        #expect((firstChatPage["items"] as? [[String: Any]])?.count == 1)
        #expect(firstChatPage["has_more"] as? Bool == true)
        let chatCursor = try #require(firstChatPage["next_cursor"] as? String)

        let secondChats = try await client.execute(
            uri: "/chats?limit=1&cursor=\(chatCursor)",
            method: .get
        )
        let secondChatPage = try pageJSONObject(secondChats.body)
        #expect((secondChatPage["items"] as? [[String: Any]])?.first?["id"] as? Int == 2)
        #expect(secondChatPage["has_more"] as? Bool == false)
        #expect(secondChatPage["next_cursor"] == nil)

        let firstHistory = try await client.execute(
            uri: "/chats/1/messages?q=fixture&limit=1",
            method: .get
        )
        let firstHistoryPage = try pageJSONObject(firstHistory.body)
        #expect((firstHistoryPage["items"] as? [[String: Any]])?.first?["id"] as? Int == 101)
        #expect(firstHistoryPage["has_more"] as? Bool == true)
        let historyCursor = try #require(firstHistoryPage["next_cursor"] as? String)

        let secondHistory = try await client.execute(
            uri: "/chats/1/messages?q=fixture&limit=1&cursor=\(historyCursor)",
            method: .get
        )
        let secondHistoryPage = try pageJSONObject(secondHistory.body)
        #expect((secondHistoryPage["items"] as? [[String: Any]])?.first?["id"] as? Int == 100)
        #expect(secondHistoryPage["has_more"] as? Bool == false)
    }
}

@Test("chat history rejects invalid and query-bound cursors")
func cursorErrors() async throws {
    let fixture = try ServerDatabaseFixture()
    try fixture.execute(
        """
        INSERT INTO message (ROWID, guid, text, is_from_me, is_read, date)
        VALUES (101, 'guid-101', 'fixture second', 0, 1, 700000000);
        INSERT INTO chat_message_join (chat_id, message_id) VALUES (1, 101);
        """)
    let app = makeTestApplication(databasePath: fixture.path)

    try await app.test(.router) { client in
        let malformed = try await client.execute(
            uri: "/chats?cursor=not-base64",
            method: .get
        )
        try expectPageError(
            malformed,
            status: .badRequest,
            message: "invalid or expired page cursor"
        )

        let first = try await client.execute(uri: "/chats/1/messages?limit=1&q=fixture", method: .get)
        let cursor = try #require(try pageJSONObject(first.body)["next_cursor"] as? String)
        for uri in [
            "/chats/2/messages?cursor=\(cursor)&q=fixture",
            "/chats/1/messages?cursor=\(cursor)&q=other",
            "/chats/1/messages?cursor=\(cursor)&q=fixture&match=exact",
        ] {
            let response = try await client.execute(uri: uri, method: .get)
            try expectPageError(response, status: .badRequest, message: "invalid or expired page cursor")
        }
    }
}
private func pageJSONObject(_ buffer: ByteBuffer) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any])
}

private func expectPageError(
    _ response: TestResponse,
    status: HTTPResponse.Status,
    message: String
) throws {
    #expect(response.status == status)
    let body = try pageJSONObject(response.body)
    let error = body["error"] as? [String: Any]
    #expect(error?["message"] as? String == message)
}
