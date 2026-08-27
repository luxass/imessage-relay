import XCTest
import Foundation
import RelayCore
@testable import relay_server

final class SSETests: XCTestCase {

    func testReadyFrameCarriesCursor() {
        XCTAssertEqual(SSE.ready(nextRowid: 42), "event: ready\ndata: {\"next_rowid\": 42}\n\n")
    }

    func testKeepaliveIsSSEComment() {
        XCTAssertEqual(SSE.keepalive, ": keepalive\n\n")
    }

    /// The stream's message frames must use the same encoding contract as the
    /// REST routes: snake_case keys, nil fields omitted.
    func testMessageFrameMatchesRESTEncoding() throws {
        let message = Message(
            id: 7,
            chatId: 1,
            guid: "guid-7",
            text: "hello",
            sender: "+15551230001",
            isFromMe: false,
            createdAt: "2026-08-24T12:00:00Z",
            replyToGuid: nil,
            isReaction: nil,
            reactedToGuid: nil
        )

        let frame = try SSE.message(message)

        // Strip the SSE framing and compare against a plain JSONEncoder pass.
        // Compared as parsed JSON since key order is not deterministic.
        XCTAssertTrue(frame.hasPrefix("event: message\ndata: "))
        XCTAssertTrue(frame.hasSuffix("\n\n"))
        let payload = String(frame.dropFirst("event: message\ndata: ".count).dropLast(2))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        XCTAssertEqual(object as NSDictionary, expected as NSDictionary)
        XCTAssertNil(object["reply_to_guid"], "nil fields must be omitted, not nulled")
        XCTAssertNil(object["is_reaction"], "nil fields must be omitted, not nulled")
        XCTAssertNotNil(object["chat_id"], "keys must stay snake_case")
    }

    func testAdvanceNeverRegressesCursor() {
        XCTAssertEqual(SSE.advance(102, pageNextRowid: 105), 105) // normal advance
        XCTAssertEqual(SSE.advance(105, pageNextRowid: 103), 105) // defensive max
        XCTAssertEqual(SSE.advance(0, pageNextRowid: 0), 0)       // empty page holds
    }
}
